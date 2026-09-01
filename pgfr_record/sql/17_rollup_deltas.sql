-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- rollup_deltas() (milestone 8): the long-horizon analog of deltas(), for
-- endpoint-shaped (Group B) rollup targets only. Reset-aware in exactly
-- the same way deltas() is -- a decreased value, or an advanced linked
-- reset_column, yields NULL rather than a bogus delta -- just sourced
-- from two rollup buckets' stored first/last endpoints instead of two
-- state_as_of() snapshots.
--
-- Stat-shaped (Group C) targets have no analog here: their rollup rows
-- are already the final per-bucket answer (a MAX/COUNT/SUM), not an
-- endpoint pair to difference -- read pgfr_record.r_<name> directly.
--
-- Returns SETOF record, like deltas(); the caller supplies a
-- column-definition list, e.g.:
--
--   SELECT * FROM pgfr_record.rollup_deltas('pg_catalog.pg_stat_all_tables', t1, t2)
--       AS d(relid oid, seq_scan_delta bigint, ..., from_bucket timestamptz, to_bucket timestamptz);
CREATE OR REPLACE FUNCTION pgfr_record.rollup_deltas(p_source_view text, p_from_bucket timestamptz, p_to_bucket timestamptz)
RETURNS SETOF record
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_manifest    record;
    v_rollup      text;
    v_unit        text;
    v_from        timestamptz;
    v_to          timestamptz;
    v_col         text;
    v_class       text;
    v_reset_col   text;
    v_type        text;
    v_select_list text[];
    v_key_list    text[];
    v_join_clause text;
    v_sql         text;
BEGIN
    SELECT * INTO v_manifest FROM pgfr_record.manifest WHERE source_view = p_source_view;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgfr_record.rollup_deltas: unknown source_view %', p_source_view;
    END IF;
    IF v_manifest.rollup_retention IS NULL THEN
        RAISE EXCEPTION 'pgfr_record.rollup_deltas: % has no rollup', p_source_view;
    END IF;
    v_rollup := 'r_' || pgfr_record._short_name(p_source_view);
    IF EXISTS (SELECT 1 FROM pgfr_record.rollup_specs WHERE source_view = p_source_view) THEN
        RAISE EXCEPTION 'pgfr_record.rollup_deltas: % has a stat-shaped rollup (already the final per-bucket value) -- read pgfr_record.% directly instead', p_source_view, v_rollup;
    END IF;

    v_unit := pgfr_record._partition_unit(v_manifest.rollup_granularity);
    v_from := date_trunc(v_unit, p_from_bucket);
    v_to   := date_trunc(v_unit, p_to_bucket);

    -- Key columns: extracted from the rollup row's own key jsonb (built
    -- the same way generate_capture_plan() builds the archive's key),
    -- typed per their own column in the current payload_schemas row.
    v_key_list := '{}';
    IF NOT (v_manifest.keyless OR array_length(v_manifest.natural_key, 1) IS NULL) THEN
        FOR v_col, v_type IN
            SELECT u.col, u.typ
            FROM pgfr_record.payload_schemas ps
            JOIN unnest(ps.columns, ps.type_names) WITH ORDINALITY AS u(col, typ, ord) ON u.col = ANY(v_manifest.natural_key)
            WHERE ps.source_view = p_source_view
              AND ps.schema_id = (SELECT max(schema_id) FROM pgfr_record.payload_schemas WHERE source_view = p_source_view)
            ORDER BY u.ord
        LOOP
            v_key_list := v_key_list || format('(t.key->>%L)::%s AS %I', v_col, v_type, v_col);
        END LOOP;
    END IF;

    -- Counter/odometer delta columns, in payload order, reset-aware
    -- exactly like deltas() (§4.5): a counter's decreased value, or its
    -- linked reset_column advancing, yields NULL; an odometer skips reset
    -- detection entirely.
    v_select_list := '{}';
    FOR v_col, v_class, v_reset_col, v_type IN
        SELECT cc.column_name, cc.class, cc.reset_column, u.typ
        FROM pgfr_record.column_classes cc
        JOIN pgfr_record.payload_schemas ps ON ps.source_view = cc.source_view
        JOIN unnest(ps.columns, ps.type_names) WITH ORDINALITY AS u(col, typ, ord) ON u.col = cc.column_name
        WHERE cc.source_view = p_source_view AND cc.class IN ('counter', 'odometer')
          AND ps.schema_id = (SELECT max(schema_id) FROM pgfr_record.payload_schemas WHERE source_view = p_source_view)
        ORDER BY u.ord
    LOOP
        IF v_class = 'counter' THEN
            IF v_reset_col IS NOT NULL THEN
                v_select_list := v_select_list || format(
                    'CASE WHEN (t.last_values->>%L)::%s < (f.first_values->>%L)::%s
                          OR (t.last_reset_values->>%L) IS DISTINCT FROM (f.first_reset_values->>%L)
                          THEN NULL ELSE (t.last_values->>%L)::%s - (f.first_values->>%L)::%s END AS %I',
                    v_col, v_type, v_col, v_type, v_reset_col, v_reset_col, v_col, v_type, v_col, v_type, v_col || '_delta'
                );
            ELSE
                v_select_list := v_select_list || format(
                    'CASE WHEN (t.last_values->>%L)::%s < (f.first_values->>%L)::%s THEN NULL
                          ELSE (t.last_values->>%L)::%s - (f.first_values->>%L)::%s END AS %I',
                    v_col, v_type, v_col, v_type, v_col, v_type, v_col, v_type, v_col || '_delta'
                );
            END IF;
        ELSE
            v_select_list := v_select_list || format(
                '((t.last_values->>%L)::%s - (f.first_values->>%L)::%s) AS %I',
                v_col, v_type, v_col, v_type, v_col || '_delta'
            );
        END IF;
    END LOOP;

    IF array_length(v_select_list, 1) IS NULL THEN
        RAISE EXCEPTION 'pgfr_record.rollup_deltas: % has no counter/odometer columns', p_source_view;
    END IF;

    IF v_manifest.keyless OR array_length(v_manifest.natural_key, 1) IS NULL THEN
        v_join_clause := 'ON true';
    ELSE
        v_join_clause := 'ON f.key_hash = t.key_hash';
    END IF;

    v_sql := format(
        'SELECT %s, f.bucket_start AS from_bucket, t.bucket_start AS to_bucket
         FROM pgfr_record.%I t
         JOIN pgfr_record.%I f %s
         WHERE t.bucket_start = %L AND f.bucket_start = %L',
        array_to_string(v_key_list || v_select_list, ', '),
        v_rollup, v_rollup, v_join_clause, v_to, v_from
    );

    RETURN QUERY EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION pgfr_record.rollup_deltas(text, timestamptz, timestamptz) IS
    'The long-horizon analog of deltas() (milestone 8), for endpoint-shaped (Group B) rollup targets: diffs the last_values of the bucket containing p_to_bucket against the first_values of the bucket containing p_from_bucket, per key, reset-aware exactly like deltas(). Raises for a stat-shaped (Group C) target -- read pgfr_record.r_<name> directly instead, its rows are already the final per-bucket value. Returns SETOF record; supply a column-definition list, e.g. rollup_deltas(''pg_catalog.pg_stat_all_tables'', t1, t2) AS d(relid oid, seq_scan_delta bigint, ..., from_bucket timestamptz, to_bucket timestamptz).';
