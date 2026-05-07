-- baseline_measure.sql — §9.2 Baseline measurements for pg_flight_recorder
-- Implements SPEC.md §9.2 "Baseline measurement — actual row counts and sizes"
-- Run against: pgfr_bench17 on port 5433 (PG 17.x)
-- Output: CSV (use psql --csv -f baseline_measure.sql)
--
-- NOTE on collection_stats.duration_ms:
--   The column stores integer milliseconds. On the cx22 benchmark VM, every
--   collection completes in < 1 ms, so duration_ms = 0 for all rows.
--   Use wall-clock timing (EXTRACT EPOCH) for fractional-ms resolution.

-- ── §9.2 Query 1: Actual row counts and bytes per row ────────────────────────
\qecho '--- Section: row_counts_and_sizes ---'

SELECT
    relname                                        AS table_name,
    n_live_tup                                     AS live_rows,
    n_dead_tup                                     AS dead_rows,
    pg_size_pretty(pg_relation_size(relid))        AS heap_size,
    pg_size_pretty(pg_total_relation_size(relid))  AS total_size,
    CASE WHEN n_live_tup > 0
         THEN pg_relation_size(relid) / n_live_tup
    END                                            AS bytes_per_row
FROM pg_stat_user_tables
WHERE schemaname = 'pgfr_record'
ORDER BY pg_total_relation_size(relid) DESC;

-- ── §9.2 Query 2: Collection latency ────────────────────────────────────────
-- Uses EXTRACT(EPOCH …) for fractional-ms precision (duration_ms is integer).
\qecho '--- Section: collection_latency ---'

SELECT
    collection_type,
    round(
        avg(EXTRACT(EPOCH FROM (completed_at - started_at)) * 1000)::numeric, 3
    )                AS avg_ms,
    round(
        max(EXTRACT(EPOCH FROM (completed_at - started_at)) * 1000)::numeric, 3
    )                AS max_ms,
    round(
        min(EXTRACT(EPOCH FROM (completed_at - started_at)) * 1000)::numeric, 3
    )                AS min_ms,
    count(*)         AS samples,
    sum(CASE WHEN success     THEN 1 ELSE 0 END) AS successes,
    sum(CASE WHEN NOT success THEN 1 ELSE 0 END) AS failures
FROM pgfr_record.collection_stats
-- Extended window: run this within 7 days of the measurement session
WHERE started_at > now() - INTERVAL '7 days'
  AND success = true
GROUP BY collection_type
ORDER BY avg_ms DESC;

-- ── §9.2 Query 3: Rows inserted per hour ────────────────────────────────────
\qecho '--- Section: rows_inserted_per_hour ---'

SELECT
    date_trunc('hour', s.captured_at) AS hour,
    count(*)                          AS rows_inserted
FROM pgfr_record.statement_snapshots ss
JOIN pgfr_record.snapshots s ON s.id = ss.snapshot_id
GROUP BY 1
ORDER BY 1;

-- ── Additional: rows per snapshot tick ──────────────────────────────────────
\qecho '--- Section: rows_per_tick ---'

SELECT
    round(avg(cnt)::numeric, 1) AS avg_rows_per_tick,
    max(cnt)                    AS max_rows_per_tick,
    min(cnt)                    AS min_rows_per_tick,
    count(DISTINCT s.id)        AS snapshot_count
FROM pgfr_record.snapshots s
JOIN (
    SELECT snapshot_id, count(*) AS cnt
    FROM pgfr_record.statement_snapshots
    GROUP BY snapshot_id
) t ON t.snapshot_id = s.id;

-- ── Additional: snapshot timing summary ─────────────────────────────────────
\qecho '--- Section: snapshot_timing_summary ---'

SELECT
    count(*)                                                    AS total_snapshots,
    min(captured_at)                                            AS first_snapshot,
    max(captured_at)                                            AS last_snapshot,
    round(
        EXTRACT(EPOCH FROM (max(captured_at) - min(captured_at))) / 3600, 2
    )                                                           AS hours_of_data
FROM pgfr_record.snapshots;

-- ── Additional: manual snapshot() wall-clock timing ─────────────────────────
-- (pg_cron overhead makes collection_stats.duration_ms unreliable)
\qecho '--- Section: manual_snapshot_timing ---'

\timing on
SELECT pgfr_record.snapshot() AS snap_ts;
\timing off

-- ── Additional: manual sample() wall-clock timing ───────────────────────────
\qecho '--- Section: manual_sample_timing ---'

\timing on
SELECT pgfr_record.sample() AS sample_ts;
\timing off

-- ── Additional: pg_stat_statements utilization ──────────────────────────────
\qecho '--- Section: pgss_utilization ---'

SELECT
    (SELECT count(*) FROM pg_stat_statements)                   AS current_statements,
    (SELECT setting::int FROM pg_settings WHERE name = 'pg_stat_statements.max')
                                                                AS max_statements,
    round(
        100.0 * (SELECT count(*) FROM pg_stat_statements) /
        (SELECT setting::int FROM pg_settings WHERE name = 'pg_stat_statements.max'),
        1
    )                                                           AS utilization_pct,
    (SELECT setting FROM pg_settings WHERE name = 'pg_stat_statements.max')
                                                                AS pgss_max_setting;

-- ── Additional: storage projection (30-day, current bytes_per_row) ───────────
\qecho '--- Section: storage_projection_30d ---'

SELECT
    50::bigint                                           AS rows_per_tick_top_n50,
    5000::bigint                                         AS rows_per_tick_pgss_max5000,
    1440::bigint                                         AS ticks_per_day,
    50::bigint  * 1440 * 30                              AS rows_30d_top_n50,
    5000::bigint * 1440 * 30                             AS rows_30d_pgss_max5000,
    (SELECT pg_relation_size(relid) / NULLIF(n_live_tup, 0)
     FROM pg_stat_user_tables
     WHERE schemaname = 'pgfr_record' AND relname = 'statement_snapshots')
                                                         AS bytes_per_row_observed,
    pg_size_pretty(
        50::bigint * 1440 * 30 *
        (SELECT pg_relation_size(relid) / NULLIF(n_live_tup, 0)
         FROM pg_stat_user_tables
         WHERE schemaname = 'pgfr_record' AND relname = 'statement_snapshots')
    )                                                    AS est_size_30d_top_n50,
    pg_size_pretty(
        5000::bigint * 1440 * 30 *
        (SELECT pg_relation_size(relid) / NULLIF(n_live_tup, 0)
         FROM pg_stat_user_tables
         WHERE schemaname = 'pgfr_record' AND relname = 'statement_snapshots')
    )                                                    AS est_size_30d_pgss_max5000;

-- ── Additional: top pgbench workload queries ─────────────────────────────────
\qecho '--- Section: pgbench_top_queries ---'

SELECT
    left(query, 80)                              AS query_preview,
    calls,
    round(total_exec_time::numeric, 2)           AS total_exec_ms,
    round(mean_exec_time::numeric, 4)            AS mean_exec_ms,
    rows
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY calls DESC
LIMIT 10;
