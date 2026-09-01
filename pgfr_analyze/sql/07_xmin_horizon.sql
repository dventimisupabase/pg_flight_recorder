-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- xmin horizon tracking: who is pinning the vacuum horizon, and how old is
-- it. Every raw xid this needs is already captured by Group C, on the fast
-- tier, under the single-stamp rule (pg_stat_activity.backend_xmin,
-- pg_stat_replication.backend_xmin, pg_replication_slots.xmin/catalog_xmin,
-- pg_prepared_xacts.transaction): no new pgfr_record capture required.
-- v1 resolved the dominant holder *inside the collector* at capture time;
-- here that resolution happens entirely in pgfr_analyze, which is where a
-- judgment call (which of several xids is "the" holder) belongs.
--
-- age(xid) is evaluated against the *current* transaction counter, since
-- that is the only counter PostgreSQL exposes: there is no way to ask "how
-- old was this xid as of its own capture time" without an independently
-- captured transaction-counter baseline, which the census does not
-- currently carry. current_xmin_horizon_holder() therefore has fully
-- correct semantics (it answers "how old is the current holder, right
-- now"); xmin_horizon_history() reports each source's single oldest
-- (worst) observation within the window, not a full per-tick timeline,
-- since a age()-per-historical-row timeline would systematically inflate
-- older rows by however much wall-clock time has passed since they were
-- captured, distorting the trend shape it would otherwise seem to show.

CREATE OR REPLACE FUNCTION pgfr_analyze.xmin_horizon_history(p_from_t timestamptz, p_to_t timestamptz)
RETURNS TABLE(source text, captured_at timestamptz, xmin_age bigint, holder jsonb)
LANGUAGE sql STABLE AS $$
    WITH candidates AS (
        SELECT 'activity'::text AS source, t.captured_at, age(t.backend_xmin) AS xmin_age, to_jsonb(t) AS holder
        FROM pgfr_record.v_pg_stat_activity t
        WHERE t.captured_at BETWEEN p_from_t AND p_to_t AND t.backend_xmin IS NOT NULL
        UNION ALL
        SELECT 'replication', t.captured_at, age(t.backend_xmin), to_jsonb(t)
        FROM pgfr_record.v_pg_stat_replication t
        WHERE t.captured_at BETWEEN p_from_t AND p_to_t AND t.backend_xmin IS NOT NULL
        UNION ALL
        SELECT 'slot', t.captured_at, age(t.xmin), to_jsonb(t)
        FROM pgfr_record.v_pg_replication_slots t
        WHERE t.captured_at BETWEEN p_from_t AND p_to_t AND t.xmin IS NOT NULL
        UNION ALL
        SELECT 'slot_catalog', t.captured_at, age(t.catalog_xmin), to_jsonb(t)
        FROM pgfr_record.v_pg_replication_slots t
        WHERE t.captured_at BETWEEN p_from_t AND p_to_t AND t.catalog_xmin IS NOT NULL
        UNION ALL
        SELECT 'prepared', t.captured_at, age(t.transaction), to_jsonb(t)
        FROM pgfr_record.v_pg_prepared_xacts t
        WHERE t.captured_at BETWEEN p_from_t AND p_to_t
    )
    SELECT DISTINCT ON (source) source, captured_at, xmin_age, holder
    FROM candidates
    ORDER BY source, xmin_age DESC;
$$;

COMMENT ON FUNCTION pgfr_analyze.xmin_horizon_history(timestamptz, timestamptz) IS
    'The single oldest (worst) xmin observation per source (activity, replication, slot, slot_catalog, prepared) captured between p_from_t and p_to_t. xmin_age is age(xid) evaluated now, so it reflects each captured value''s distance from the current horizon, not its age as of its own capture time.';

CREATE OR REPLACE FUNCTION pgfr_analyze.current_xmin_horizon_holder()
RETURNS TABLE(source text, captured_at timestamptz, xmin_age bigint, holder jsonb)
LANGUAGE sql STABLE AS $$
    WITH latest_tick AS (
        SELECT max(captured_at) AS tick_ts FROM pgfr_record.a_pg_stat_activity
    ),
    candidates AS (
        SELECT 'activity'::text AS source, t.captured_at, age(t.backend_xmin) AS xmin_age, to_jsonb(t) AS holder, 3 AS priority
        FROM pgfr_record.v_pg_stat_activity t, latest_tick lt
        WHERE t.captured_at = lt.tick_ts AND t.backend_xmin IS NOT NULL
        UNION ALL
        SELECT 'replication', t.captured_at, age(t.backend_xmin), to_jsonb(t), 4
        FROM pgfr_record.v_pg_stat_replication t, latest_tick lt
        WHERE t.captured_at = lt.tick_ts AND t.backend_xmin IS NOT NULL
        UNION ALL
        SELECT 'slot', t.captured_at, age(t.xmin), to_jsonb(t), 1
        FROM pgfr_record.v_pg_replication_slots t, latest_tick lt
        WHERE t.captured_at = lt.tick_ts AND t.xmin IS NOT NULL
        UNION ALL
        SELECT 'slot_catalog', t.captured_at, age(t.catalog_xmin), to_jsonb(t), 1
        FROM pgfr_record.v_pg_replication_slots t, latest_tick lt
        WHERE t.captured_at = lt.tick_ts AND t.catalog_xmin IS NOT NULL
        UNION ALL
        SELECT 'prepared', t.captured_at, age(t.transaction), to_jsonb(t), 2
        FROM pgfr_record.v_pg_prepared_xacts t, latest_tick lt
        WHERE t.captured_at = lt.tick_ts
    )
    SELECT source, captured_at, xmin_age, holder
    FROM candidates
    ORDER BY xmin_age DESC, priority ASC
    LIMIT 1;
$$;

COMMENT ON FUNCTION pgfr_analyze.current_xmin_horizon_holder() IS
    'The single dominant xmin-horizon holder as of the most recent fast-tier capture: whichever of activity/replication/slot/slot_catalog/prepared currently has the oldest xmin, ties broken slot > prepared > activity > replication. Zero rows when the most recent capture has no candidate in any source. Always returns the current dominant holder regardless of how old it is; applying a threshold to call that concerning is pgfr_analyze''s anomaly-detection layer, not this function.';
