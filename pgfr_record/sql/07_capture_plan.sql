-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Capture plan (§4.3.3): the ordered, per-tier list of targets the
-- collector (milestone 2, 08_collector.sql) iterates. Materialized so a
-- tier job looks up a cheap, pre-resolved plan on every tick rather than
-- re-joining the manifest and re-fingerprinting live views on every
-- capture.
--
-- capture_plan is regenerated wholesale on every call (TRUNCATE +
-- repopulate), not appended to. Invariant 1's "no UPDATE, no DELETE,
-- anywhere" governs the *record* -- archive tables, payload_schemas, the
-- ledger -- because those are the observed history an agent must be able
-- to trust and reconstruct (§1). capture_plan is derived configuration
-- cache, not observed history, exactly like the manifest table itself
-- (which operators are expected to edit directly, e.g. §10.2's "at ~10^5
-- relations, Group B cadence should be slowed or targets disabled in the
-- manifest") and like presentation views (CREATE OR REPLACE, not
-- appended). Regenerating it wholesale is the same operation class as
-- generate_presentation_views(), just against a table instead of a view.
--
-- Per-target timeout resolution is deliberately not stored here: profiles
-- (cadence + lock_timeout + section_timeout bounds) are milestone 5.
-- capture_plan carries everything the manifest layer owns today; a
-- profile is joined against it at collector-run time once one exists.
CREATE TABLE IF NOT EXISTS pgfr_record.capture_plan (
  cadence_tier      text NOT NULL,
  plan_order        int NOT NULL,
  source_view       text NOT NULL,
  archive_table     text NOT NULL,
  schema_id         smallint NOT NULL REFERENCES pgfr_record.payload_schemas,
  natural_key       text[] NOT NULL,
  keyless           boolean NOT NULL,
  debounce          boolean NOT NULL,
  compare_ignore    text[] NOT NULL,
  anchor_every      interval,
  retention         interval NOT NULL,
  capture_select_sql text NOT NULL,
  PRIMARY KEY (cadence_tier, plan_order)
);

COMMENT ON TABLE pgfr_record.capture_plan IS
    'Per-tier, ordered list of (source_view, archive_table, schema_id, debounce, anchor, ...) the collector iterates (§4.3.3, §5). Regenerated wholesale by generate_capture_plan(); derived cache, not observed history -- see the comment above its DDL for why this table does not fall under invariant 1''s append-only rule.';
COMMENT ON COLUMN pgfr_record.capture_plan.plan_order IS 'Position within this tier, in manifest order (source_view, ascending) -- the "ORDER BY manifest order" of §5''s collector pseudocode.';
COMMENT ON COLUMN pgfr_record.capture_plan.schema_id IS 'The current payload_schemas row for this target at plan-generation time; re-resolved on every generate_capture_plan() run, never edited in place.';
COMMENT ON COLUMN pgfr_record.capture_plan.capture_select_sql IS
    'Cached SELECT of (key, key_hash, row_hash, payload) from the live source_view -- the "capture statement" half of §4.4''s mint-together invariant, generated atomically alongside schema_id from the same live-column introspection. The collector wraps it in an INSERT ... SELECT, adding the debounce anti-join when applicable; it never re-introspects columns per tick.';

-- Column list + type names for a source_view, translated into the SQL
-- fragments generate_capture_plan() needs: the key extractor, the
-- row-hash compare payload (with compare_ignore columns nulled, §6), and
-- the stored payload array -- all driven by the manifest's own natural_key/
-- compare_ignore/keyless facts, never by guessing at column semantics.
CREATE OR REPLACE FUNCTION pgfr_record.generate_capture_plan()
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_row           record;
    v_i             int;
    v_col           text;
    v_payload_exprs text[];
    v_compare_exprs text[];
    v_key_exprs     text[];
    v_key_expr      text;
    v_key_hash_expr text;
    v_row_hash_expr text;
    v_select_sql    text;
    v_tier          text;
    v_order         int;
BEGIN
    TRUNCATE pgfr_record.capture_plan;

    v_tier := NULL;
    v_order := 0;
    FOR v_row IN
        SELECT m.*, ps.schema_id, ps.columns, ps.type_names
        FROM pgfr_record.manifest m
        JOIN LATERAL (
            SELECT schema_id, columns, type_names
            FROM pgfr_record.payload_schemas p
            WHERE p.source_view = m.source_view
            ORDER BY p.schema_id DESC
            LIMIT 1
        ) ps ON true
        WHERE m.enabled
          AND m.min_major <= pgfr_record._current_major()
          AND pgfr_record._current_major() <= coalesce(m.max_major, 999)
        ORDER BY m.cadence_tier, m.source_view
    LOOP
        IF v_tier IS DISTINCT FROM v_row.cadence_tier THEN
            v_tier := v_row.cadence_tier;
            v_order := 0;
        END IF;
        v_order := v_order + 1;

        -- payload: every column, in schema order. compare payload: the
        -- same, with compare_ignore columns nulled (§6) -- stored intact,
        -- compared blind.
        v_payload_exprs := '{}';
        v_compare_exprs := '{}';
        FOR v_i IN 1..array_length(v_row.columns, 1) LOOP
            v_col := v_row.columns[v_i];
            v_payload_exprs := v_payload_exprs || format('%I', v_col);
            IF v_col = ANY(v_row.compare_ignore) THEN
                v_compare_exprs := v_compare_exprs || 'NULL'::text;
            ELSE
                v_compare_exprs := v_compare_exprs || format('%I', v_col);
            END IF;
        END LOOP;

        -- key / key_hash: NULL for keyless or singleton (empty
        -- natural_key) targets; otherwise a jsonb object over the
        -- natural_key columns.
        IF v_row.keyless OR array_length(v_row.natural_key, 1) IS NULL THEN
            v_key_expr := 'NULL::jsonb';
            v_key_hash_expr := 'NULL::bigint';
        ELSE
            v_key_exprs := '{}';
            FOR v_i IN 1..array_length(v_row.natural_key, 1) LOOP
                v_col := v_row.natural_key[v_i];
                v_key_exprs := v_key_exprs || format('%L, %I', v_col, v_col);
            END LOOP;
            v_key_expr := format('jsonb_build_object(%s)', array_to_string(v_key_exprs, ', '));
            v_key_hash_expr := format('hashtextextended((%s)::text, 0)', v_key_expr);
        END IF;

        -- row_hash includes schema_id in the compared text (§6), as a
        -- literal baked in at plan-generation time, so a shape change
        -- always registers as a change independent of the live values.
        v_row_hash_expr := format(
            'hashtextextended(%L || (jsonb_build_array(%s))::text, 0)',
            v_row.schema_id::text || ':', array_to_string(v_compare_exprs, ', ')
        );

        v_select_sql := format(
            'SELECT %s AS key, %s AS key_hash, %s AS row_hash, jsonb_build_array(%s) AS payload FROM %s',
            v_key_expr, v_key_hash_expr, v_row_hash_expr,
            array_to_string(v_payload_exprs, ', '), v_row.source_view
        );

        INSERT INTO pgfr_record.capture_plan
            (cadence_tier, plan_order, source_view, archive_table, schema_id,
             natural_key, keyless, debounce, compare_ignore, anchor_every, retention, capture_select_sql)
        VALUES
            (v_row.cadence_tier, v_order, v_row.source_view, 'a_' || pgfr_record._short_name(v_row.source_view),
             v_row.schema_id, v_row.natural_key, v_row.keyless, v_row.debounce, v_row.compare_ignore,
             v_row.anchor_every, v_row.retention, v_select_sql);
    END LOOP;
END;
$$;

COMMENT ON FUNCTION pgfr_record.generate_capture_plan() IS
    'Rebuilds pgfr_record.capture_plan wholesale from the manifest joined to each target''s current payload_schemas row, minting each row''s capture_select_sql from the same live-column introspection (§4.4 mint-together invariant). A target with no minted schema yet (unmet precondition, or generate_archives() not yet run) is absent from the plan, not present with a NULL schema_id. Regenerate whenever the manifest changes (§4.3.3); safe to re-run.';
