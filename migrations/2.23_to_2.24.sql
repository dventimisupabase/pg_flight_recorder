-- =============================================================================
-- Migration: 2.23 to 2.24
-- =============================================================================
-- Description: Vacuum Control Enhancements
--
-- Changes:
--   - Add vacuum_control_state table for tracking vacuum operating modes
--   - Add reltuples, vacuum_running, last_vacuum_duration_ms to table_snapshots
--   - Add vacuum control config parameters
--   - Add helper and core vacuum control functions
--
-- Data preservation: Existing data unchanged, new columns will be NULL for
--                    historical snapshots and populated going forward
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- =============================================================================
-- Step 1: Version Guard
-- =============================================================================
DO $$
DECLARE
    v_current TEXT;
    v_expected TEXT := '2.23';
    v_target TEXT := '2.24';
BEGIN
    SELECT value INTO v_current
    FROM flight_recorder.config WHERE key = 'schema_version';

    IF v_current IS NULL THEN
        RAISE EXCEPTION 'schema_version not found. Is Flight Recorder installed?';
    END IF;

    IF v_current != v_expected THEN
        RAISE EXCEPTION 'Migration 2.23->2.24 requires version %, found %', v_expected, v_current;
    END IF;

    RAISE NOTICE 'Migrating from % to %...', v_expected, v_target;
END $$;

-- =============================================================================
-- Step 2: Schema Changes - New Table
-- =============================================================================

-- Tracks vacuum operating mode and recommendation state per table
-- Note: Only stores OID per project policy; join to pg_class for names
CREATE TABLE IF NOT EXISTS flight_recorder.vacuum_control_state (
    relid                           OID PRIMARY KEY,
    operating_mode                  TEXT NOT NULL DEFAULT 'normal',
    mode_entered_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_recommendation_at          TIMESTAMPTZ,
    last_recommended_scale_factor   NUMERIC,
    consecutive_budget_exceeded     INTEGER NOT NULL DEFAULT 0,
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE flight_recorder.vacuum_control_state IS 'Tracks vacuum operating mode (normal/catch_up/safety) and recommendation state per table for closed-loop vacuum control';

-- =============================================================================
-- Step 3: Schema Changes - New Columns (Data Preserving)
-- =============================================================================

-- Add new columns to table_snapshots
ALTER TABLE flight_recorder.table_snapshots
    ADD COLUMN IF NOT EXISTS reltuples BIGINT;

ALTER TABLE flight_recorder.table_snapshots
    ADD COLUMN IF NOT EXISTS vacuum_running BOOLEAN;

ALTER TABLE flight_recorder.table_snapshots
    ADD COLUMN IF NOT EXISTS last_vacuum_duration_ms BIGINT;

-- =============================================================================
-- Step 4: Configuration Parameters
-- =============================================================================

INSERT INTO flight_recorder.config (key, value)
VALUES
    ('vacuum_control_enabled', 'true'),
    ('vacuum_control_dead_tuple_budget_pct', '5'),
    ('vacuum_control_min_scale_factor', '0.001'),
    ('vacuum_control_max_scale_factor', '0.2'),
    ('vacuum_control_hysteresis_pct', '25'),
    ('vacuum_control_rate_limit_minutes', '60'),
    ('vacuum_control_catchup_budget_hours', '4')
ON CONFLICT (key) DO NOTHING;

-- =============================================================================
-- Step 5: Helper Functions
-- =============================================================================

-- Returns table-specific autovacuum settings, falling back to global defaults
CREATE OR REPLACE FUNCTION flight_recorder._get_table_autovacuum_settings(
    p_relid OID
)
RETURNS TABLE(
    scale_factor        NUMERIC,
    threshold           INTEGER,
    enabled             BOOLEAN,
    source              TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_reloptions TEXT[];
    v_opt TEXT;
    v_scale_factor NUMERIC;
    v_threshold INTEGER;
    v_enabled BOOLEAN;
    v_source TEXT := 'global';
BEGIN
    -- Get global defaults
    SELECT setting::numeric INTO v_scale_factor
    FROM pg_settings WHERE name = 'autovacuum_vacuum_scale_factor';
    v_scale_factor := COALESCE(v_scale_factor, 0.2);

    SELECT setting::integer INTO v_threshold
    FROM pg_settings WHERE name = 'autovacuum_vacuum_threshold';
    v_threshold := COALESCE(v_threshold, 50);

    v_enabled := true;

    -- Check table-specific reloptions
    SELECT c.reloptions INTO v_reloptions
    FROM pg_class c
    WHERE c.oid = p_relid;

    IF v_reloptions IS NOT NULL THEN
        FOREACH v_opt IN ARRAY v_reloptions LOOP
            IF v_opt LIKE 'autovacuum_vacuum_scale_factor=%' THEN
                v_scale_factor := substring(v_opt from '=(.*)$')::numeric;
                v_source := 'table';
            ELSIF v_opt LIKE 'autovacuum_vacuum_threshold=%' THEN
                v_threshold := substring(v_opt from '=(.*)$')::integer;
                v_source := 'table';
            ELSIF v_opt LIKE 'autovacuum_enabled=%' THEN
                v_enabled := substring(v_opt from '=(.*)$')::boolean;
                v_source := 'table';
            END IF;
        END LOOP;
    END IF;

    RETURN QUERY SELECT v_scale_factor, v_threshold, v_enabled, v_source;
END;
$$;
COMMENT ON FUNCTION flight_recorder._get_table_autovacuum_settings(OID) IS 'Returns autovacuum settings for a table, with fallback to global defaults';

-- Calculates dead tuple trend (slope) using linear regression over a time window
CREATE OR REPLACE FUNCTION flight_recorder.dead_tuple_trend(
    p_relid OID,
    p_window INTERVAL
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_slope NUMERIC;
    v_count INTEGER;
BEGIN
    -- Use linear regression to determine trend
    SELECT
        count(*),
        regr_slope(n_dead_tup::numeric, EXTRACT(EPOCH FROM s.captured_at))
    INTO v_count, v_slope
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND s.captured_at >= now() - p_window
      AND ts.n_dead_tup IS NOT NULL;

    -- Need at least 2 points for meaningful regression
    IF v_count < 2 THEN
        RETURN NULL;
    END IF;

    -- Return tuples per second (slope of regression line)
    RETURN ROUND(v_slope, 4);
END;
$$;
COMMENT ON FUNCTION flight_recorder.dead_tuple_trend(OID, INTERVAL) IS 'Returns dead tuple accumulation trend (tuples/second) using linear regression';

-- =============================================================================
-- Step 6: Core Vacuum Control Functions
-- =============================================================================

-- Determines operating mode for a table (normal, catch_up, safety)
CREATE OR REPLACE FUNCTION flight_recorder.vacuum_control_mode(
    p_relid OID
)
RETURNS TABLE(
    mode        TEXT,
    reason      TEXT,
    entered_at  TIMESTAMPTZ,
    evidence    TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_exists BOOLEAN;
    v_xid_age INTEGER;
    v_freeze_max_age BIGINT;
    v_xid_threshold BIGINT;
    v_dead_trend NUMERIC;
    v_time_to_exhaust INTERVAL;
    v_budget_hours INTEGER;
    v_has_blocking_txn BOOLEAN;
    v_current_mode TEXT;
    v_mode_entered TIMESTAMPTZ;
BEGIN
    -- Check if table exists
    SELECT EXISTS(SELECT 1 FROM pg_class WHERE oid = p_relid) INTO v_exists;
    IF NOT v_exists THEN
        RETURN QUERY SELECT NULL::TEXT, NULL::TEXT, NULL::TIMESTAMPTZ, NULL::TEXT;
        RETURN;
    END IF;

    -- Get current state if exists
    SELECT vcs.operating_mode, vcs.mode_entered_at
    INTO v_current_mode, v_mode_entered
    FROM flight_recorder.vacuum_control_state vcs
    WHERE vcs.relid = p_relid;

    v_current_mode := COALESCE(v_current_mode, 'normal');
    v_mode_entered := COALESCE(v_mode_entered, now());

    -- Get freeze_max_age for XID calculations
    SELECT setting::bigint INTO v_freeze_max_age
    FROM pg_settings WHERE name = 'autovacuum_freeze_max_age';
    v_freeze_max_age := COALESCE(v_freeze_max_age, 200000000);
    v_xid_threshold := (v_freeze_max_age * 0.5)::bigint;  -- 50% of freeze_max_age

    -- Check XID age
    SELECT age(c.relfrozenxid)::integer INTO v_xid_age
    FROM pg_class c
    WHERE c.oid = p_relid;

    -- SAFETY MODE: XID age approaching wraparound
    IF COALESCE(v_xid_age, 0) > v_xid_threshold THEN
        RETURN QUERY SELECT
            'safety'::TEXT,
            'XID age exceeds 50% of autovacuum_freeze_max_age'::TEXT,
            CASE WHEN v_current_mode = 'safety' THEN v_mode_entered ELSE now() END,
            format('XID age: %s, threshold: %s', v_xid_age, v_xid_threshold)::TEXT;
        RETURN;
    END IF;

    -- Check for blocking transactions
    SELECT EXISTS(
        SELECT 1 FROM pg_stat_activity
        WHERE state = 'idle in transaction'
          AND now() - xact_start > interval '30 minutes'
    ) INTO v_has_blocking_txn;

    -- SAFETY MODE: Long-running idle transactions blocking vacuum
    IF v_has_blocking_txn THEN
        RETURN QUERY SELECT
            'safety'::TEXT,
            'Long-running idle transactions may be blocking vacuum'::TEXT,
            CASE WHEN v_current_mode = 'safety' THEN v_mode_entered ELSE now() END,
            'Idle in transaction sessions older than 30 minutes detected'::TEXT;
        RETURN;
    END IF;

    -- Check dead tuple trend for catch-up mode
    v_dead_trend := flight_recorder.dead_tuple_trend(p_relid, '1 hour'::interval);

    -- Get budget hours config
    v_budget_hours := COALESCE(
        flight_recorder._get_config('vacuum_control_catchup_budget_hours', '4')::integer,
        4
    );

    -- Get time to budget exhaustion
    v_time_to_exhaust := flight_recorder.time_to_budget_exhaustion(
        p_relid,
        (SELECT COALESCE(ts.reltuples, ts.n_live_tup, 0) *
                flight_recorder._get_config('vacuum_control_dead_tuple_budget_pct', '5')::numeric / 100
         FROM flight_recorder.table_snapshots ts
         JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
         WHERE ts.relid = p_relid
         ORDER BY s.captured_at DESC LIMIT 1)::bigint
    );

    -- CATCH_UP MODE: Dead tuples growing and budget exhaustion imminent
    IF v_dead_trend IS NOT NULL AND v_dead_trend > 0
       AND v_time_to_exhaust IS NOT NULL
       AND v_time_to_exhaust < make_interval(hours => v_budget_hours) THEN
        RETURN QUERY SELECT
            'catch_up'::TEXT,
            'Dead tuples growing, budget exhaustion imminent'::TEXT,
            CASE WHEN v_current_mode = 'catch_up' THEN v_mode_entered ELSE now() END,
            format('Trend: %s tuples/sec, time to exhaustion: %s', v_dead_trend, v_time_to_exhaust)::TEXT;
        RETURN;
    END IF;

    -- NORMAL MODE: Default steady-state
    RETURN QUERY SELECT
        'normal'::TEXT,
        'Vacuum keeping up with workload'::TEXT,
        CASE WHEN v_current_mode = 'normal' THEN v_mode_entered ELSE now() END,
        NULL::TEXT;
END;
$$;
COMMENT ON FUNCTION flight_recorder.vacuum_control_mode(OID) IS 'Determines vacuum operating mode (normal/catch_up/safety) for a table based on XID age and dead tuple trends';

-- Computes recommended autovacuum_vacuum_scale_factor based on control law
CREATE OR REPLACE FUNCTION flight_recorder.compute_recommended_scale_factor(
    p_relid OID
)
RETURNS TABLE(
    current_scale_factor        NUMERIC,
    recommended_scale_factor    NUMERIC,
    change_pct                  NUMERIC,
    rationale                   TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_exists BOOLEAN;
    v_reltuples BIGINT;
    v_n_dead_tup BIGINT;
    v_current_sf NUMERIC;
    v_threshold INTEGER;
    v_budget_pct NUMERIC;
    v_min_sf NUMERIC;
    v_max_sf NUMERIC;
    v_dead_budget BIGINT;
    v_recommended_sf NUMERIC;
    v_change_pct NUMERIC;
    v_rationale TEXT;
BEGIN
    -- Check if table exists
    SELECT EXISTS(SELECT 1 FROM pg_class WHERE oid = p_relid) INTO v_exists;
    IF NOT v_exists THEN
        RETURN QUERY SELECT NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::TEXT;
        RETURN;
    END IF;

    -- Get current settings
    SELECT scale_factor, threshold INTO v_current_sf, v_threshold
    FROM flight_recorder._get_table_autovacuum_settings(p_relid);

    -- Get config values
    v_budget_pct := COALESCE(
        flight_recorder._get_config('vacuum_control_dead_tuple_budget_pct', '5')::numeric,
        5
    );
    v_min_sf := COALESCE(
        flight_recorder._get_config('vacuum_control_min_scale_factor', '0.001')::numeric,
        0.001
    );
    v_max_sf := COALESCE(
        flight_recorder._get_config('vacuum_control_max_scale_factor', '0.2')::numeric,
        0.2
    );

    -- Get current table stats
    SELECT COALESCE(ts.reltuples, ts.n_live_tup), ts.n_dead_tup
    INTO v_reltuples, v_n_dead_tup
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
    ORDER BY s.captured_at DESC
    LIMIT 1;

    -- Handle missing data
    IF v_reltuples IS NULL OR v_reltuples = 0 THEN
        RETURN QUERY SELECT
            v_current_sf,
            NULL::NUMERIC,
            NULL::NUMERIC,
            'Insufficient data: no row count available'::TEXT;
        RETURN;
    END IF;

    -- Calculate dead tuple budget
    v_dead_budget := (v_reltuples * v_budget_pct / 100)::bigint;

    -- Control law: scale_factor = (dead_budget - threshold) / reltuples
    -- This ensures vacuum triggers when dead tuples reach budget
    IF v_dead_budget > v_threshold THEN
        v_recommended_sf := (v_dead_budget - v_threshold)::numeric / v_reltuples;
    ELSE
        v_recommended_sf := v_min_sf;
    END IF;

    -- Clamp to bounds
    v_recommended_sf := GREATEST(v_min_sf, LEAST(v_max_sf, v_recommended_sf));
    v_recommended_sf := ROUND(v_recommended_sf, 4);

    -- Calculate change percentage
    IF v_current_sf > 0 THEN
        v_change_pct := ROUND(((v_recommended_sf - v_current_sf) / v_current_sf) * 100, 1);
    ELSE
        v_change_pct := NULL;
    END IF;

    -- Build rationale
    v_rationale := format(
        'Budget: %s%% of %s rows = %s dead tuples. Current threshold triggers at %s + %s%% = %s rows.',
        v_budget_pct, v_reltuples, v_dead_budget,
        v_threshold, ROUND(v_current_sf * 100, 2),
        v_threshold + ROUND(v_current_sf * v_reltuples)
    );

    RETURN QUERY SELECT v_current_sf, v_recommended_sf, v_change_pct, v_rationale;
END;
$$;
COMMENT ON FUNCTION flight_recorder.compute_recommended_scale_factor(OID) IS 'Computes recommended autovacuum_vacuum_scale_factor to maintain dead tuple budget';

-- Classifies vacuum failure mode for diagnostic purposes
CREATE OR REPLACE FUNCTION flight_recorder.vacuum_diagnostic(
    p_relid OID
)
RETURNS TABLE(
    classification  TEXT,
    evidence        TEXT,
    confidence      TEXT,
    likely_cause    TEXT,
    mitigation      TEXT,
    mitigation_sql  TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_exists BOOLEAN;
    v_schemaname TEXT;
    v_relname TEXT;
    v_n_dead_tup BIGINT;
    v_autovacuum_count BIGINT;
    v_last_autovacuum TIMESTAMPTZ;
    v_vacuum_running BOOLEAN;
    v_dead_trend NUMERIC;
    v_has_blocking_txn BOOLEAN;
    v_autovacuum_workers INTEGER;
    v_max_workers INTEGER;
    v_classification TEXT;
    v_evidence TEXT;
    v_confidence TEXT;
    v_likely_cause TEXT;
    v_mitigation TEXT;
    v_mitigation_sql TEXT;
BEGIN
    -- Check if table exists
    SELECT EXISTS(SELECT 1 FROM pg_class WHERE oid = p_relid) INTO v_exists;
    IF NOT v_exists THEN
        RETURN QUERY SELECT NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
        RETURN;
    END IF;

    -- Get table name
    SELECT n.nspname, c.relname INTO v_schemaname, v_relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = p_relid;

    -- Get latest stats
    SELECT ts.n_dead_tup, ts.autovacuum_count, ts.last_autovacuum, ts.vacuum_running
    INTO v_n_dead_tup, v_autovacuum_count, v_last_autovacuum, v_vacuum_running
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
    ORDER BY s.captured_at DESC
    LIMIT 1;

    -- Get dead tuple trend
    v_dead_trend := flight_recorder.dead_tuple_trend(p_relid, '1 hour'::interval);

    -- Check for blocking transactions
    SELECT EXISTS(
        SELECT 1 FROM pg_stat_activity
        WHERE state = 'idle in transaction'
          AND now() - xact_start > interval '10 minutes'
    ) INTO v_has_blocking_txn;

    -- Get autovacuum worker counts
    SELECT count(*)::integer INTO v_autovacuum_workers
    FROM pg_stat_activity
    WHERE backend_type = 'autovacuum worker';

    SELECT setting::integer INTO v_max_workers
    FROM pg_settings WHERE name = 'autovacuum_max_workers';
    v_max_workers := COALESCE(v_max_workers, 3);

    -- Classification logic
    IF v_has_blocking_txn THEN
        -- BLOCKED: Long-running transactions preventing vacuum progress
        v_classification := 'BLOCKED';
        v_evidence := 'Long-running idle in transaction sessions detected';
        v_confidence := 'high';
        v_likely_cause := 'Idle transactions holding back vacuum horizon';
        v_mitigation := 'Identify and terminate idle transactions, consider idle_in_transaction_session_timeout';
        v_mitigation_sql := format(
            'SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = ''idle in transaction'' AND now() - xact_start > interval ''30 minutes'';'
        );
    ELSIF v_vacuum_running AND v_dead_trend IS NOT NULL AND v_dead_trend > 0 THEN
        -- RUNNING_BUT_LOSING: Vacuum running but not keeping up
        v_classification := 'RUNNING_BUT_LOSING';
        v_evidence := format('Vacuum running but dead tuples still growing at %s/sec', v_dead_trend);
        v_confidence := 'medium';
        v_likely_cause := 'Vacuum throughput insufficient for workload';
        v_mitigation := 'Increase autovacuum_vacuum_cost_limit or reduce autovacuum_vacuum_cost_delay';
        v_mitigation_sql := 'ALTER SYSTEM SET autovacuum_vacuum_cost_limit = 2000; SELECT pg_reload_conf();';
    ELSIF v_autovacuum_workers >= v_max_workers AND v_dead_trend IS NOT NULL AND v_dead_trend > 0 THEN
        -- NOT_SCHEDULED: Workers saturated, table waiting in queue
        v_classification := 'NOT_SCHEDULED';
        v_evidence := format('All %s autovacuum workers busy, dead tuples growing', v_max_workers);
        v_confidence := 'medium';
        v_likely_cause := 'autovacuum_max_workers too low for workload';
        v_mitigation := 'Increase autovacuum_max_workers or tune scale_factor to reduce vacuum frequency';
        v_mitigation_sql := 'ALTER SYSTEM SET autovacuum_max_workers = 6; SELECT pg_reload_conf();';
    ELSIF COALESCE(v_n_dead_tup, 0) = 0 OR (v_dead_trend IS NULL OR v_dead_trend <= 0) THEN
        -- HEALTHY: No dead tuple accumulation
        v_classification := 'HEALTHY';
        v_evidence := 'Dead tuples stable or decreasing';
        v_confidence := 'high';
        v_likely_cause := 'Vacuum keeping up with workload';
        v_mitigation := 'No action required';
        v_mitigation_sql := NULL;
    ELSE
        -- NOT_SCHEDULED: Default when dead tuples growing but no obvious cause
        v_classification := 'NOT_SCHEDULED';
        v_evidence := format('Dead tuples: %s, trend: %s/sec, last vacuum: %s',
                            v_n_dead_tup, COALESCE(v_dead_trend::text, 'unknown'),
                            COALESCE(v_last_autovacuum::text, 'never'));
        v_confidence := 'low';
        v_likely_cause := 'Table not reaching vacuum threshold or autovacuum disabled';
        v_mitigation := 'Lower autovacuum_vacuum_scale_factor for this table';
        v_mitigation_sql := format(
            'ALTER TABLE %I.%I SET (autovacuum_vacuum_scale_factor = 0.05);',
            v_schemaname, v_relname
        );
    END IF;

    RETURN QUERY SELECT v_classification, v_evidence, v_confidence, v_likely_cause, v_mitigation, v_mitigation_sql;
END;
$$;
COMMENT ON FUNCTION flight_recorder.vacuum_diagnostic(OID) IS 'Classifies vacuum failure mode (NOT_SCHEDULED/RUNNING_BUT_LOSING/BLOCKED/HEALTHY) with actionable guidance';

-- Main vacuum control report function
CREATE OR REPLACE FUNCTION flight_recorder.vacuum_control_report(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    schemaname                  TEXT,
    relname                     TEXT,
    relid                       OID,
    operating_mode              TEXT,
    mode_reason                 TEXT,
    diagnostic_classification   TEXT,
    diagnostic_confidence       TEXT,
    current_scale_factor        NUMERIC,
    recommended_scale_factor    NUMERIC,
    change_pct                  NUMERIC,
    should_recommend            BOOLEAN,
    last_recommendation_at      TIMESTAMPTZ,
    alter_table_sql             TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_enabled BOOLEAN;
    v_hysteresis_pct NUMERIC;
    v_rate_limit_minutes INTEGER;
BEGIN
    -- Check if feature is enabled
    v_enabled := COALESCE(
        flight_recorder._get_config('vacuum_control_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Get config values
    v_hysteresis_pct := COALESCE(
        flight_recorder._get_config('vacuum_control_hysteresis_pct', '25')::numeric,
        25
    );
    v_rate_limit_minutes := COALESCE(
        flight_recorder._get_config('vacuum_control_rate_limit_minutes', '60')::integer,
        60
    );

    RETURN QUERY
    WITH latest_snapshots AS (
        SELECT DISTINCT ON (ts.relid)
            ts.relid,
            ts.schemaname,
            ts.relname,
            ts.n_dead_tup,
            ts.reltuples,
            ts.n_live_tup
        FROM flight_recorder.table_snapshots ts
        JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
        WHERE s.captured_at BETWEEN p_start_time AND p_end_time
        ORDER BY ts.relid, s.captured_at DESC
    ),
    mode_info AS (
        SELECT
            ls.relid,
            (flight_recorder.vacuum_control_mode(ls.relid)).*
        FROM latest_snapshots ls
    ),
    diag_info AS (
        SELECT
            ls.relid,
            (flight_recorder.vacuum_diagnostic(ls.relid)).*
        FROM latest_snapshots ls
    ),
    scale_info AS (
        SELECT
            ls.relid,
            (flight_recorder.compute_recommended_scale_factor(ls.relid)).*
        FROM latest_snapshots ls
    ),
    state_info AS (
        SELECT
            vcs.relid,
            vcs.last_recommendation_at,
            vcs.last_recommended_scale_factor
        FROM flight_recorder.vacuum_control_state vcs
    )
    SELECT
        ls.schemaname,
        ls.relname,
        ls.relid,
        mi.mode AS operating_mode,
        mi.reason AS mode_reason,
        di.classification AS diagnostic_classification,
        di.confidence AS diagnostic_confidence,
        si.current_scale_factor,
        si.recommended_scale_factor,
        si.change_pct,
        -- Should recommend: passes hysteresis AND rate limit
        CASE
            WHEN si.recommended_scale_factor IS NULL THEN false
            WHEN ABS(COALESCE(si.change_pct, 0)) < v_hysteresis_pct THEN false
            WHEN sti.last_recommendation_at IS NOT NULL
                 AND sti.last_recommendation_at > now() - make_interval(mins => v_rate_limit_minutes)
                 THEN false
            ELSE true
        END AS should_recommend,
        sti.last_recommendation_at,
        -- Generate ALTER TABLE SQL
        CASE
            WHEN si.recommended_scale_factor IS NOT NULL
                 AND ABS(COALESCE(si.change_pct, 0)) >= v_hysteresis_pct
            THEN format(
                'ALTER TABLE %I.%I SET (autovacuum_vacuum_scale_factor = %s);',
                ls.schemaname, ls.relname, si.recommended_scale_factor
            )
            ELSE NULL
        END AS alter_table_sql
    FROM latest_snapshots ls
    LEFT JOIN mode_info mi ON mi.relid = ls.relid
    LEFT JOIN diag_info di ON di.relid = ls.relid
    LEFT JOIN scale_info si ON si.relid = ls.relid
    LEFT JOIN state_info sti ON sti.relid = ls.relid
    WHERE mi.mode IS NOT NULL
    ORDER BY
        CASE mi.mode
            WHEN 'safety' THEN 1
            WHEN 'catch_up' THEN 2
            ELSE 3
        END,
        COALESCE(ls.n_dead_tup, 0) DESC;
END;
$$;
COMMENT ON FUNCTION flight_recorder.vacuum_control_report(TIMESTAMPTZ, TIMESTAMPTZ) IS 'Returns vacuum control recommendations for all monitored tables with hysteresis and rate limiting';

-- =============================================================================
-- Step 7: Update Version
-- =============================================================================
UPDATE flight_recorder.config
SET value = '2.24', updated_at = now()
WHERE key = 'schema_version';

COMMIT;

-- =============================================================================
-- Step 8: Post-migration verification
-- =============================================================================
DO $$
DECLARE
    v_version TEXT;
    v_table_exists BOOLEAN;
    v_reltuples_exists BOOLEAN;
    v_vacuum_running_exists BOOLEAN;
    v_duration_exists BOOLEAN;
    v_config_count INTEGER;
    v_mode_func_exists BOOLEAN;
    v_sf_func_exists BOOLEAN;
    v_diag_func_exists BOOLEAN;
    v_report_func_exists BOOLEAN;
BEGIN
    SELECT value INTO v_version
    FROM flight_recorder.config WHERE key = 'schema_version';

    -- Verify vacuum_control_state table exists
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'flight_recorder'
          AND table_name = 'vacuum_control_state'
    ) INTO v_table_exists;

    -- Verify new columns exist
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'flight_recorder'
          AND table_name = 'table_snapshots'
          AND column_name = 'reltuples'
    ) INTO v_reltuples_exists;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'flight_recorder'
          AND table_name = 'table_snapshots'
          AND column_name = 'vacuum_running'
    ) INTO v_vacuum_running_exists;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'flight_recorder'
          AND table_name = 'table_snapshots'
          AND column_name = 'last_vacuum_duration_ms'
    ) INTO v_duration_exists;

    -- Verify config parameters exist
    SELECT count(*) INTO v_config_count
    FROM flight_recorder.config
    WHERE key IN (
        'vacuum_control_enabled',
        'vacuum_control_dead_tuple_budget_pct',
        'vacuum_control_min_scale_factor',
        'vacuum_control_max_scale_factor',
        'vacuum_control_hysteresis_pct',
        'vacuum_control_rate_limit_minutes',
        'vacuum_control_catchup_budget_hours'
    );

    -- Verify functions exist
    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'flight_recorder' AND p.proname = 'vacuum_control_mode'
    ) INTO v_mode_func_exists;

    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'flight_recorder' AND p.proname = 'compute_recommended_scale_factor'
    ) INTO v_sf_func_exists;

    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'flight_recorder' AND p.proname = 'vacuum_diagnostic'
    ) INTO v_diag_func_exists;

    SELECT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'flight_recorder' AND p.proname = 'vacuum_control_report'
    ) INTO v_report_func_exists;

    IF NOT v_table_exists THEN
        RAISE WARNING 'vacuum_control_state table not found';
    END IF;

    IF NOT v_reltuples_exists THEN
        RAISE WARNING 'reltuples column not found in table_snapshots';
    END IF;

    IF NOT v_vacuum_running_exists THEN
        RAISE WARNING 'vacuum_running column not found in table_snapshots';
    END IF;

    IF NOT v_duration_exists THEN
        RAISE WARNING 'last_vacuum_duration_ms column not found in table_snapshots';
    END IF;

    IF v_config_count < 7 THEN
        RAISE WARNING 'Some vacuum_control config parameters not found (found %/7)', v_config_count;
    END IF;

    IF NOT v_mode_func_exists THEN
        RAISE WARNING 'vacuum_control_mode function not found';
    END IF;

    IF NOT v_sf_func_exists THEN
        RAISE WARNING 'compute_recommended_scale_factor function not found';
    END IF;

    IF NOT v_diag_func_exists THEN
        RAISE WARNING 'vacuum_diagnostic function not found';
    END IF;

    IF NOT v_report_func_exists THEN
        RAISE WARNING 'vacuum_control_report function not found';
    END IF;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration Complete ===';
    RAISE NOTICE 'Now at version: %', v_version;
    RAISE NOTICE '';
    RAISE NOTICE 'Added vacuum control enhancements:';
    RAISE NOTICE '  - vacuum_control_state table (mode tracking per table)';
    RAISE NOTICE '  - table_snapshots.reltuples (estimated row count)';
    RAISE NOTICE '  - table_snapshots.vacuum_running (vacuum in progress flag)';
    RAISE NOTICE '  - table_snapshots.last_vacuum_duration_ms (vacuum timing)';
    RAISE NOTICE '';
    RAISE NOTICE 'New configuration parameters:';
    RAISE NOTICE '  - vacuum_control_enabled: Enable/disable vacuum control features';
    RAISE NOTICE '  - vacuum_control_dead_tuple_budget_pct: Target dead tuple budget';
    RAISE NOTICE '  - vacuum_control_min/max_scale_factor: Bounds for recommendations';
    RAISE NOTICE '  - vacuum_control_hysteresis_pct: Minimum change to recommend';
    RAISE NOTICE '  - vacuum_control_rate_limit_minutes: Time between recommendations';
    RAISE NOTICE '';
    RAISE NOTICE 'New functions:';
    RAISE NOTICE '  - vacuum_control_mode(relid): Get operating mode (normal/catch_up/safety)';
    RAISE NOTICE '  - compute_recommended_scale_factor(relid): Calculate optimal scale_factor';
    RAISE NOTICE '  - vacuum_diagnostic(relid): Classify vacuum issues';
    RAISE NOTICE '  - vacuum_control_report(start, end): Full recommendations report';
    RAISE NOTICE '';
END $$;
