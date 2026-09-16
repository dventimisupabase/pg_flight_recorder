-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Configuration tracking. pg_settings is already a debounced Group D
-- manifest target with full history (GUC change detection falls out of
-- debounce for free), so this needs no dedicated snapshot table: it reads
-- pgfr_record.state_as_of() at two points in time and diffs the result,
-- the same pattern pgfr_record.deltas() itself uses internally.

CREATE OR REPLACE FUNCTION pgfr_analyze.config_changes(p_from_t timestamptz, p_to_t timestamptz)
RETURNS TABLE(name text, old_setting text, new_setting text, old_source text, new_source text, changed_at timestamptz)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_ps       record;
    v_col_defs text;
    v_sql      text;
BEGIN
    SELECT columns, type_names INTO v_ps
    FROM pgfr_record.payload_schemas
    WHERE source_view = 'pg_catalog.pg_settings'
    ORDER BY schema_id DESC LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgfr_analyze.config_changes: no payload schema minted yet for pg_catalog.pg_settings';
    END IF;

    SELECT 'captured_at timestamptz, ' || string_agg(format('%I %s', c, t), ', ' ORDER BY ord)
    INTO v_col_defs
    FROM unnest(v_ps.columns, v_ps.type_names) WITH ORDINALITY AS u(c, t, ord);

    v_sql := format(
        $q$
        SELECT coalesce(t.name, f.name), f.setting, t.setting, f.source, t.source, t.captured_at
        FROM pgfr_record.state_as_of('pg_catalog.pg_settings', %L::timestamptz) AS t(%s)
        FULL JOIN pgfr_record.state_as_of('pg_catalog.pg_settings', %L::timestamptz) AS f(%s)
            USING (name)
        WHERE t.setting IS DISTINCT FROM f.setting OR t.source IS DISTINCT FROM f.source
        ORDER BY 1
        $q$,
        p_to_t, v_col_defs, p_from_t, v_col_defs
    );

    RETURN QUERY EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.config_changes(timestamptz, timestamptz) IS
    'GUCs whose setting or source differ between the state as of p_from_t and as of p_to_t (both reconstructed via pgfr_record.state_as_of()). changed_at is the actual capture timestamp of the p_to_t value, not a precisely-detected change moment.';

CREATE OR REPLACE FUNCTION pgfr_analyze.config_at(p_t timestamptz, p_name_prefix text DEFAULT NULL)
RETURNS TABLE(name text, setting text, source text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_ps       record;
    v_col_defs text;
    v_pattern  text := p_name_prefix || '%';
    v_sql      text;
BEGIN
    SELECT columns, type_names INTO v_ps
    FROM pgfr_record.payload_schemas
    WHERE source_view = 'pg_catalog.pg_settings'
    ORDER BY schema_id DESC LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgfr_analyze.config_at: no payload schema minted yet for pg_catalog.pg_settings';
    END IF;

    SELECT 'captured_at timestamptz, ' || string_agg(format('%I %s', c, t), ', ' ORDER BY ord)
    INTO v_col_defs
    FROM unnest(v_ps.columns, v_ps.type_names) WITH ORDINALITY AS u(c, t, ord);

    v_sql := format(
        $q$
        SELECT name, setting, source
        FROM pgfr_record.state_as_of('pg_catalog.pg_settings', %L::timestamptz) AS t(%s)
        WHERE %L::text IS NULL OR name LIKE %L
        ORDER BY name
        $q$,
        p_t, v_col_defs, p_name_prefix, v_pattern
    );

    RETURN QUERY EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.config_at(timestamptz, text) IS
    'GUC values as of p_t (LOCF via pgfr_record.state_as_of()), optionally filtered to names starting with p_name_prefix.';

-- Live-catalog checks, not historical: reads pg_settings directly, the
-- same way pgfr_record.health_check() reads live structural facts rather
-- than an opinion about what's normal.
CREATE OR REPLACE FUNCTION pgfr_analyze.config_health_check()
RETURNS TABLE(parameter_name text, current_value text, issue text, recommendation text)
LANGUAGE sql STABLE AS $$
    SELECT 'shared_buffers', setting || unit, 'Low shared_buffers', format('Consider raising shared_buffers (currently %s%s)', setting, unit)
    FROM pg_settings
    WHERE name = 'shared_buffers'
      AND setting::bigint * (CASE unit WHEN '8kB' THEN 8192 WHEN 'kB' THEN 1024 ELSE 1 END) < 128 * 1024 * 1024
    UNION ALL
    SELECT 'work_mem', setting || unit, 'Low work_mem', format('Consider raising work_mem (currently %s%s)', setting, unit)
    FROM pg_settings
    WHERE name = 'work_mem'
      AND setting::bigint * (CASE unit WHEN 'kB' THEN 1024 ELSE 1 END) < 16 * 1024 * 1024
    UNION ALL
    SELECT 'max_connections', setting, 'High max_connections', format('Consider a connection pooler (currently %s)', setting)
    FROM pg_settings
    WHERE name = 'max_connections' AND setting::int > 200
    UNION ALL
    SELECT 'statement_timeout', setting, 'No statement_timeout', 'Consider setting a statement_timeout'
    FROM pg_settings
    WHERE name = 'statement_timeout' AND setting = '0';
$$;

COMMENT ON FUNCTION pgfr_analyze.config_health_check() IS
    'Opinionated checks against the live (not historical) pg_settings: shared_buffers, work_mem, max_connections, statement_timeout. Returns zero rows when nothing is flagged.';
