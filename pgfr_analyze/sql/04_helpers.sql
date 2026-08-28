-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Shared internal helper. Several pgfr_analyze functions call
-- pgfr_record.deltas() against views whose column set varies by
-- PostgreSQL major (pg_stat_statements most notably); the caller must
-- supply a column-definition list matching that view's *current* shape,
-- with counter/odometer columns renamed to <col>_delta. Building that list
-- by hand per function risks getting it subtly wrong on some major; this
-- is the one place that logic lives.

CREATE OR REPLACE FUNCTION pgfr_analyze._deltas_col_defs(p_source_view text)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT string_agg(
        CASE
            WHEN cc.class IN ('counter', 'odometer')
                THEN format('%I %s', u.c || '_delta', CASE WHEN u.t = 'pg_lsn' THEN 'numeric' ELSE u.t END)
            ELSE format('%I %s', u.c, u.t)
        END,
        ', ' ORDER BY u.ord
    ) || ', from_captured_at timestamptz, to_captured_at timestamptz'
    FROM (
        SELECT columns, type_names
        FROM pgfr_record.payload_schemas
        WHERE source_view = p_source_view
        ORDER BY schema_id DESC LIMIT 1
    ) ps,
    unnest(ps.columns, ps.type_names) WITH ORDINALITY AS u(c, t, ord)
    JOIN pgfr_record.column_classes cc ON cc.source_view = p_source_view AND cc.column_name = u.c;
$$;

COMMENT ON FUNCTION pgfr_analyze._deltas_col_defs(text) IS
    'Column-definition list for pgfr_record.deltas(p_source_view, ...), matching that view''s current schema_id shape: counter/odometer columns renamed to <col>_delta, everything else passed through under its own name. NULL when no payload schema has been minted yet for p_source_view.';
