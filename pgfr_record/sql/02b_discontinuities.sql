-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

--------------------------------------------------------------------------------
-- Discontinuity and censoring events as first-class data (Issue #101).
--
-- Mode B's failure mode is discontinuity, not noise: counter resets, crash
-- recovery, pg_stat_statements eviction, and the ring's deliberate
-- truncate-on-flush-failure path all invalidate measurements that span them.
-- Until now the codebase detected several of these (reset sentinels in the
-- consumption sampler, stats_reset tracking in the sparse PGSS collector)
-- and then discarded the fact. This ledger records each event so that:
--
--   - delta readers can return NULL-with-reason instead of clamped or
--     nonsense values,
--   - the trend engines can treat restarts and resets as known segment
--     boundaries instead of discovering them as changepoints,
--   - coverage() can attribute gaps to recorded restarts,
--   - humans can answer "did anything invalidate this window?" with a query.
--
-- Deliberately a plain LOGGED heap: a censoring ledger whose whole purpose is
-- surviving a crash must not be UNLOGGED (contrast collection_stats), and it
-- is deliberately not partitioned and has no retention, like
-- pgfr_analyze.consumption_trends: it IS the long-term memory, and its write
-- rate is bounded by how often counters reset (a handful of rows per restart
-- or reset, rate-limited for eviction pressure).
--
-- Loaded early (02b) so every later collector file can call
-- _record_discontinuity() regardless of its own language or load position.
--------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgfr_record.discontinuities (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    detected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    event_kind  TEXT NOT NULL CHECK (event_kind IN (
        'stats_reset',              -- a cumulative-counter family reset (scope says which)
        'pgss_reset',               -- pg_stat_statements_info.stats_reset advanced
        'pgss_eviction_pressure',   -- pg_stat_statements dealloc churn (right-censoring)
        'restart',                  -- postmaster start time changed
        'rollup_flush_failed'       -- ring slot truncated after its rollup flush failed
    )),
    scope       TEXT NOT NULL,
    evidence    JSONB
);

CREATE INDEX IF NOT EXISTS discontinuities_detected_at_idx
    ON pgfr_record.discontinuities (detected_at);
CREATE INDEX IF NOT EXISTS discontinuities_kind_detected_idx
    ON pgfr_record.discontinuities (event_kind, detected_at);

COMMENT ON TABLE pgfr_record.discontinuities IS
'Censoring-event ledger (Issue #101): one row per detected discontinuity in the recorder''s inputs. Deltas spanning one of these events are invalid measurements, not noisy ones; readers return NULL-with-reason, trend engines take these as known segment boundaries, and coverage() uses restart rows for gap attribution. LOGGED (survives crashes), unpartitioned, no retention: this is the long-term memory of when the instrument''s baselines moved.';

COMMENT ON COLUMN pgfr_record.discontinuities.detected_at IS
'When the recorder noticed the event (the collection tick that observed it), not when the underlying reset/restart actually happened; the true time lies between the previous tick and this one.';
COMMENT ON COLUMN pgfr_record.discontinuities.event_kind IS
'What kind of censoring event: stats_reset (a counter family reset; scope names it), pgss_reset (pg_stat_statements reset), pgss_eviction_pressure (statement cache churn, right-censoring of low-frequency queries), restart (postmaster start time changed), rollup_flush_failed (a ring slot was truncated even though its archive rollup failed, destroying that window''s Mode A samples).';
COMMENT ON COLUMN pgfr_record.discontinuities.scope IS
'Which counter family, subsystem, or object the event censors: pg_stat_database, pg_stat_wal, checkpointer_bgwriter, pg_stat_statements, postmaster, or the archive rollup table name for flush failures.';
COMMENT ON COLUMN pgfr_record.discontinuities.evidence IS
'Machine-readable detail for the event: previous and current sentinel values, error text for flush failures, slot numbers and window bounds, dealloc counts. Shape varies by event_kind.';

-- Append-only writer for the ledger. Never raises: a broken evidence payload
-- or transient failure must not take down the collector that detected the
-- event (the same rule the collectors apply to their own sections).
CREATE OR REPLACE FUNCTION pgfr_record._record_discontinuity(
    p_event_kind TEXT,
    p_scope      TEXT,
    p_evidence   JSONB DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO pgfr_record.discontinuities (event_kind, scope, evidence)
    VALUES (p_event_kind, p_scope, p_evidence);
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'pgfr_record: failed to record % discontinuity (%): %',
        p_event_kind, p_scope, SQLERRM;
END;
$$;

COMMENT ON FUNCTION pgfr_record._record_discontinuity(TEXT, TEXT, JSONB) IS
'Appends one censoring event to pgfr_record.discontinuities. Swallows its own failures with a warning so detection can never break collection.';

-- Restart detection: compares pg_postmaster_start_time() against the last
-- value seen (config key last_postmaster_start). Called at the head of
-- snapshot(), before the circuit breaker, so every tick checks. The first
-- ever observation seeds the key without emitting an event (a fresh install
-- is not a restart).
CREATE OR REPLACE FUNCTION pgfr_record._detect_restart()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_current TIMESTAMPTZ := pg_postmaster_start_time();
    v_last    TIMESTAMPTZ;
BEGIN
    SELECT value::timestamptz INTO v_last
    FROM pgfr_record.config WHERE key = 'last_postmaster_start';

    IF v_last IS NOT NULL AND v_current > v_last THEN
        PERFORM pgfr_record._record_discontinuity(
            'restart', 'postmaster',
            jsonb_build_object(
                'previous_start', v_last,
                'current_start',  v_current
            ));
    END IF;

    IF v_last IS DISTINCT FROM v_current THEN
        INSERT INTO pgfr_record.config (key, value, updated_at)
        VALUES ('last_postmaster_start', v_current::text, now())
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'pgfr_record: restart detection failed: %', SQLERRM;
END;
$$;

COMMENT ON FUNCTION pgfr_record._detect_restart() IS
'Detects postmaster restarts by comparing pg_postmaster_start_time() against the last_postmaster_start config key, and records a restart discontinuity when it advances. Seeds silently on first observation. Never raises.';
