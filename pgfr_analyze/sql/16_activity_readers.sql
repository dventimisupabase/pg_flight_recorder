-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Three straightforward readers, each a thin presentation over a single
-- source: vacuum_progress() and long_running_transactions() are
-- current-state reads via latest_state() (no capture is ever "the" vacuum
-- or transaction; it's whatever is in flight as of p_t; latest_state(),
-- not state_as_of(), because both source views are non-debounced Group C
-- targets, where a vanished key must actually disappear, not carry
-- forward as stale via LOCF); wal_archiver_status() is a deltas() window
-- like every other Group A rate/count check.

-- vacuum_progress(): in-flight VACUUM operations as of p_t. relname isn't
-- captured directly on pg_stat_progress_vacuum (only relid is), so it's
-- resolved via resolve_relation(), which survives OID reuse across
-- DROP/CREATE by reading src_catalog_identity's history rather than the
-- live catalog. PG17 replaced tuple-count dead-tuple tracking
-- (num_dead_tuples/max_dead_tuples) with byte-based tracking
-- (dead_tuple_bytes/max_dead_tuple_bytes); rather than expose either
-- version's raw, differently-united counters directly, both collapse into
-- one version-stable percentage (how full the dead-tuple buffer is).
CREATE OR REPLACE FUNCTION pgfr_analyze.vacuum_progress(p_t timestamptz DEFAULT clock_timestamp())
RETURNS TABLE(pid int, datname text, relname text, phase text, pct_scanned numeric, pct_vacuumed numeric, pct_dead_tuple_buffer numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col_defs   text := pgfr_analyze._state_col_defs('pg_catalog.pg_stat_progress_vacuum');
    v_dead_col   text := CASE WHEN pgfr_record._current_major() >= 17 THEN 'dead_tuple_bytes' ELSE 'num_dead_tuples' END;
    v_max_col    text := CASE WHEN pgfr_record._current_major() >= 17 THEN 'max_dead_tuple_bytes' ELSE 'max_dead_tuples' END;
    v_sql        text;
BEGIN
    IF v_col_defs IS NULL THEN
        RAISE EXCEPTION 'pgfr_analyze.vacuum_progress: no payload schema minted yet for pg_stat_progress_vacuum';
    END IF;

    v_sql := format(
        $q$
        SELECT pid, datname::text,
               coalesce((SELECT rr.relname::text FROM pgfr_record.resolve_relation(relid, %2$L::timestamptz) rr), relid::text),
               phase,
               CASE WHEN heap_blks_total > 0 THEN round(100.0 * heap_blks_scanned / heap_blks_total, 1) ELSE NULL END,
               CASE WHEN heap_blks_total > 0 THEN round(100.0 * heap_blks_vacuumed / heap_blks_total, 1) ELSE NULL END,
               CASE WHEN %4$I > 0 THEN round(100.0 * %5$I / %4$I, 1) ELSE NULL END
        FROM pgfr_record.latest_state(%1$L, %2$L::timestamptz) AS d(%3$s)
        $q$,
        'pg_catalog.pg_stat_progress_vacuum', p_t, v_col_defs, v_max_col, v_dead_col
    );
    RETURN QUERY EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.vacuum_progress(timestamptz) IS
    'VACUUM operations in flight as of p_t (default now), from pg_stat_progress_vacuum via latest_state() (not state_as_of(): a finished vacuum must actually disappear, not carry forward as a stale row). relname is resolved via resolve_relation() since only relid is captured directly. pct_scanned/pct_vacuumed are heap_blks_scanned/heap_blks_vacuumed as a percent of heap_blks_total; pct_dead_tuple_buffer is the dead-tuple tracking buffer''s fill percentage (num_dead_tuples/max_dead_tuples pre-PG17, dead_tuple_bytes/max_dead_tuple_bytes on PG17+, collapsed into one version-stable percentage since the two majors track different units). All three are NULL before their denominator is known.';

-- wal_archiver_status(): archiving throughput and failures over a window.
CREATE OR REPLACE FUNCTION pgfr_analyze.wal_archiver_status(p_from_t timestamptz, p_to_t timestamptz)
RETURNS TABLE(archived_delta bigint, failed_delta bigint, last_archived_wal text, last_archived_time timestamptz, last_failed_wal text, last_failed_time timestamptz)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col_defs text := pgfr_analyze._deltas_col_defs('pg_catalog.pg_stat_archiver');
    v_sql      text;
BEGIN
    IF v_col_defs IS NULL THEN
        RAISE EXCEPTION 'pgfr_analyze.wal_archiver_status: no payload schema minted yet for pg_stat_archiver';
    END IF;

    v_sql := format(
        $q$
        SELECT archived_count_delta, failed_count_delta, last_archived_wal, last_archived_time, last_failed_wal, last_failed_time
        FROM pgfr_record.deltas('pg_catalog.pg_stat_archiver', %L::timestamptz, %L::timestamptz) AS d(%s)
        $q$,
        p_from_t, p_to_t, v_col_defs
    );
    RETURN QUERY EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.wal_archiver_status(timestamptz, timestamptz) IS
    'WAL archiving activity between p_from_t and p_to_t, from pg_stat_archiver deltas(): archived_delta/failed_delta are counts in the window; last_archived_wal/last_archived_time/last_failed_wal/last_failed_time are the end-of-window values (archiver-reported, not window-relative).';

-- long_running_transactions(): any backend whose transaction has been open
-- longer than p_threshold as of p_t, regardless of state (broader than
-- anomaly_report()'s IDLE_IN_TRANSACTION check, which only flags idle ones).
CREATE OR REPLACE FUNCTION pgfr_analyze.long_running_transactions(p_t timestamptz DEFAULT clock_timestamp(), p_threshold interval DEFAULT interval '5 minutes')
RETURNS TABLE(pid int, usename text, application_name text, state text, xact_age interval, query text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col_defs text := pgfr_analyze._state_col_defs('pg_catalog.pg_stat_activity');
    v_sql      text;
BEGIN
    IF v_col_defs IS NULL THEN
        RAISE EXCEPTION 'pgfr_analyze.long_running_transactions: no payload schema minted yet for pg_stat_activity';
    END IF;

    v_sql := format(
        $q$
        SELECT pid, usename::text, application_name, state, (%1$L::timestamptz - xact_start), query
        FROM pgfr_record.latest_state(%2$L, %1$L::timestamptz) AS d(%3$s)
        WHERE xact_start IS NOT NULL AND %1$L::timestamptz - xact_start > %4$L::interval
        ORDER BY xact_start
        $q$,
        p_t, 'pg_catalog.pg_stat_activity', v_col_defs, p_threshold
    );
    RETURN QUERY EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.long_running_transactions(timestamptz, interval) IS
    'Backends whose transaction has been open longer than p_threshold (default 5 minutes) as of p_t (default now), from pg_stat_activity via latest_state() (not state_as_of(): a disconnected backend must actually disappear, not carry forward as a false long-running transaction), any state -- broader than anomaly_report()''s IDLE_IN_TRANSACTION check, which only flags backends idle inside their transaction.';
