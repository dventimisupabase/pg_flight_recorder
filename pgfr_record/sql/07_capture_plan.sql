-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Capture plan (§4.3.3): the ordered, per-tier list of targets the
-- collector (milestone 2) iterates. Materialized so a tier job looks up
-- a cheap, pre-resolved plan on every tick rather than re-joining the
-- manifest and re-fingerprinting live views on every capture.
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
  cadence_tier   text NOT NULL,
  plan_order     int NOT NULL,
  source_view    text NOT NULL,
  archive_table  text NOT NULL,
  schema_id      smallint NOT NULL REFERENCES pgfr_record.payload_schemas,
  natural_key    text[] NOT NULL,
  keyless        boolean NOT NULL,
  debounce       boolean NOT NULL,
  compare_ignore text[] NOT NULL,
  anchor_every   interval,
  PRIMARY KEY (cadence_tier, plan_order)
);

COMMENT ON TABLE pgfr_record.capture_plan IS
    'Per-tier, ordered list of (source_view, archive_table, schema_id, debounce, anchor, ...) the collector iterates (§4.3.3, §5). Regenerated wholesale by generate_capture_plan(); derived cache, not observed history -- see the comment above its DDL for why this table does not fall under invariant 1''s append-only rule.';
COMMENT ON COLUMN pgfr_record.capture_plan.plan_order IS 'Position within this tier, in manifest order (source_view, ascending) -- the "ORDER BY manifest order" of §5''s collector pseudocode.';
COMMENT ON COLUMN pgfr_record.capture_plan.schema_id IS 'The current payload_schemas row for this target at plan-generation time; re-resolved on every generate_capture_plan() run, never edited in place.';

CREATE OR REPLACE FUNCTION pgfr_record.generate_capture_plan()
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE pgfr_record.capture_plan;

    INSERT INTO pgfr_record.capture_plan
        (cadence_tier, plan_order, source_view, archive_table, schema_id,
         natural_key, keyless, debounce, compare_ignore, anchor_every)
    SELECT
        m.cadence_tier,
        (row_number() OVER (PARTITION BY m.cadence_tier ORDER BY m.source_view))::int,
        m.source_view,
        'a_' || pgfr_record._short_name(m.source_view),
        ps.schema_id,
        m.natural_key,
        m.keyless,
        m.debounce,
        m.compare_ignore,
        m.anchor_every
    FROM pgfr_record.manifest m
    JOIN LATERAL (
        SELECT schema_id
        FROM pgfr_record.payload_schemas p
        WHERE p.source_view = m.source_view
        ORDER BY p.schema_id DESC
        LIMIT 1
    ) ps ON true
    WHERE m.enabled
      AND m.min_major <= pgfr_record._current_major()
      AND pgfr_record._current_major() <= coalesce(m.max_major, 999);
END;
$$;

COMMENT ON FUNCTION pgfr_record.generate_capture_plan() IS
    'Rebuilds pgfr_record.capture_plan wholesale from the manifest joined to each target''s current payload_schemas row. A target with no minted schema yet (unmet precondition, or generate_archives() not yet run) is absent from the plan, not present with a NULL schema_id. Regenerate whenever the manifest changes (§4.3.3); safe to re-run.';
