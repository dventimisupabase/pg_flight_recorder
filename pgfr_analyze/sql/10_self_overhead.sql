-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Self-overhead budget: the recorder reports its own perturbation as part
-- of the same measurement discipline it applies everywhere else. Every
-- figure is self-measured at call time -- from pgfr_record.ledger_runs
-- (per-tier tick duration) and pgfr_record.deltas() over pg_statio_all_tables
-- (the recorder's own share of block traffic) for the window, plus two
-- live reads (storage footprint, pg_stat_statements time share) that are
-- inherently point-in-time rather than window-relative.

CREATE OR REPLACE FUNCTION pgfr_analyze.self_overhead(p_from_t timestamptz, p_to_t timestamptz)
RETURNS TABLE(metric text, value numeric, units text, method text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_statio_col_defs text := pgfr_analyze._deltas_col_defs('pg_catalog.pg_statio_all_tables');
    v_recorder_blocks  numeric;
    v_total_blocks     numeric;
    v_storage_bytes    numeric;
    v_pgss_share       numeric;
    v_sql              text;
    v_row              record;
BEGIN
    IF v_statio_col_defs IS NULL THEN
        RAISE EXCEPTION 'pgfr_analyze.self_overhead: no payload schema minted yet for pg_statio_all_tables';
    END IF;

    -- Per-tier tick duration: ledger_runs is written once per completed
    -- tier run (§5), so finished_at - captured_at is the run's true
    -- wall-clock cost, no capture needed to measure it.
    FOR v_row IN
        SELECT tier, avg(extract(epoch FROM (finished_at - captured_at)) * 1000) AS ms
        FROM pgfr_record.ledger_runs
        WHERE captured_at BETWEEN p_from_t AND p_to_t
        GROUP BY tier
    LOOP
        metric := v_row.tier || '_ms_per_tick';
        value := round(v_row.ms::numeric, 1);
        units := 'milliseconds';
        method := format('avg(finished_at - captured_at) over pgfr_record.ledger_runs rows for the %s tier in the window', v_row.tier);
        RETURN NEXT;
    END LOOP;

    -- Recorder block share: the recorder's own schemas' share of total
    -- block hit/read traffic, from pg_statio_all_tables deltas in the
    -- window. schemaname is captured directly on this view -- no join to
    -- resolve_relation() needed.
    v_sql := format(
        $q$
        SELECT
            sum(heap_blks_hit_delta + heap_blks_read_delta + idx_blks_hit_delta + idx_blks_read_delta + tidx_blks_hit_delta + tidx_blks_read_delta + toast_blks_hit_delta + toast_blks_read_delta) FILTER (WHERE schemaname IN ('pgfr_record', 'pgfr_analyze')),
            sum(heap_blks_hit_delta + heap_blks_read_delta + idx_blks_hit_delta + idx_blks_read_delta + tidx_blks_hit_delta + tidx_blks_read_delta + toast_blks_hit_delta + toast_blks_read_delta)
        FROM pgfr_record.deltas('pg_catalog.pg_statio_all_tables', %L::timestamptz, %L::timestamptz) AS d(%s)
        $q$,
        p_from_t, p_to_t, v_statio_col_defs
    );
    EXECUTE v_sql INTO v_recorder_blocks, v_total_blocks;

    IF v_total_blocks IS NOT NULL AND v_total_blocks > 0 THEN
        metric := 'recorder_block_share';
        value := round(coalesce(v_recorder_blocks, 0) / v_total_blocks, 6);
        units := 'fraction';
        method := 'sum of block hit/read deltas over relations in the pgfr_record/pgfr_analyze schemas, against the same sum across every relation, from pg_statio_all_tables deltas() in the window';
        RETURN NEXT;
    END IF;

    -- Storage footprint: live at call time, not window-relative -- bounded
    -- by each target's manifest retention, so this converges rather than
    -- growing without limit.
    SELECT sum(pg_total_relation_size(c.oid)) INTO v_storage_bytes
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('pgfr_record', 'pgfr_analyze') AND c.relkind IN ('r', 'm');

    metric := 'storage_bytes';
    value := v_storage_bytes;
    units := 'bytes';
    method := 'sum(pg_total_relation_size) over ordinary and materialized relations in the pgfr_record and pgfr_analyze schemas (includes indexes and TOAST), read live at call time; bounded by each target''s manifest retention, so this converges rather than growing without limit';
    RETURN NEXT;

    -- pg_stat_statements time share: the recorder's own queries are part
    -- of the population it samples. Live at call time (since last reset),
    -- not window-relative; guarded because the extension is optional.
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        EXECUTE $q$
            SELECT round((sum(total_exec_time) FILTER (WHERE query ILIKE '%pgfr\_%') / nullif(sum(total_exec_time), 0))::numeric, 6)
            FROM pg_stat_statements
        $q$ INTO v_pgss_share;

        IF v_pgss_share IS NOT NULL THEN
            metric := 'pgss_time_share';
            value := v_pgss_share;
            units := 'fraction';
            method := 'pgfr-attributed total_exec_time over all total_exec_time in pg_stat_statements since its last reset (statements whose text references a pgfr_ schema), read live at call time';
            RETURN NEXT;
        END IF;
    END IF;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.self_overhead(timestamptz, timestamptz) IS
    'Self-measured observer-effect budget: per-tier tick duration from ledger_runs, the recorder''s own share of block traffic from pg_statio_all_tables deltas (both over the given window), plus live storage footprint and pg_stat_statements time share (both inherently point-in-time). A metric is absent when the window or the live state holds no evidence for it (e.g. a fresh install, or pg_stat_statements not installed).';
