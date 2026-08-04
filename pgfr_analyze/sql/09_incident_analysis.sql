-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

CREATE OR REPLACE FUNCTION pgfr_analyze.what_happened_at(
    p_timestamp TIMESTAMPTZ,
    p_context_window INTERVAL DEFAULT '5 minutes'
)
RETURNS TABLE(
    -- Temporal context
    requested_time TIMESTAMPTZ,
    sample_before TIMESTAMPTZ,
    sample_after TIMESTAMPTZ,
    snapshot_before TIMESTAMPTZ,
    snapshot_after TIMESTAMPTZ,

    -- Interpolated state from snapshots
    est_connections_active NUMERIC,
    est_connections_total NUMERIC,
    est_xact_rate NUMERIC,
    est_blks_hit_ratio NUMERIC,

    -- Exact-timestamp events (from activity samples)
    events JSONB,

    -- Activity analysis (from activity samples ring buffer)
    sessions_active INTEGER,
    long_running_queries INTEGER,
    longest_query_secs NUMERIC,

    -- Lock analysis
    lock_contention_detected BOOLEAN,
    blocked_sessions INTEGER,

    -- Wait events
    top_wait_events JSONB,

    -- Confidence assessment
    confidence TEXT,
    confidence_score NUMERIC,
    data_quality_notes TEXT[],

    -- Actionable recommendations
    recommendations TEXT[]
)
LANGUAGE plpgsql AS $$
DECLARE
    -- Snapshot data
    v_snap_before RECORD;
    v_snap_after RECORD;
    v_snap_gap_secs NUMERIC;

    -- Sample data (v2 ring; legacy samples_ring path retired)
    v_sample_ts_before    int4;
    v_sample_ts_after     int4;
    v_captured_before     timestamptz;
    v_captured_after      timestamptz;
    v_sample_gap_secs     NUMERIC;

    -- Interpolated values
    v_est_active NUMERIC;
    v_est_total NUMERIC;
    v_est_xact_rate NUMERIC;
    v_est_hit_ratio NUMERIC;

    -- Events array
    v_events JSONB := '[]'::jsonb;
    v_event JSONB;

    -- Activity analysis
    v_sessions INTEGER := 0;
    v_long_running INTEGER := 0;
    v_longest_secs NUMERIC := 0;

    -- Lock analysis
    v_lock_detected BOOLEAN := FALSE;
    v_blocked INTEGER := 0;

    -- Wait events
    v_waits JSONB := '[]'::jsonb;

    -- Confidence calculation
    v_confidence_score NUMERIC := 0.5;
    v_confidence_level TEXT := 'low';
    v_notes TEXT[] := ARRAY[]::TEXT[];
    v_recs TEXT[] := ARRAY[]::TEXT[];

    -- Context window bounds
    v_window_start TIMESTAMPTZ;
    v_window_end TIMESTAMPTZ;

BEGIN
    -- Calculate window bounds
    v_window_start := p_timestamp - p_context_window;
    v_window_end := p_timestamp + p_context_window;

    -- ==========================================================================
    -- STEP 1: Find surrounding snapshots
    -- ==========================================================================
    SELECT * INTO v_snap_before
    FROM pgfr_record.snapshots
    WHERE captured_at <= p_timestamp
    ORDER BY captured_at DESC
    LIMIT 1;

    SELECT * INTO v_snap_after
    FROM pgfr_record.snapshots
    WHERE captured_at >= p_timestamp
    ORDER BY captured_at ASC
    LIMIT 1;

    -- Calculate snapshot gap
    IF v_snap_before IS NOT NULL AND v_snap_after IS NOT NULL THEN
        v_snap_gap_secs := EXTRACT(EPOCH FROM (v_snap_after.captured_at - v_snap_before.captured_at));
    END IF;

    -- ==========================================================================
    -- STEP 2: Find surrounding samples from the v2 ring (activity_samples).
    -- ==========================================================================
    SELECT sample_ts,
           pgfr_record.epoch() + sample_ts * interval '1 second'
    INTO   v_sample_ts_before, v_captured_before
    FROM   pgfr_record.activity_samples
    WHERE  pgfr_record.epoch() + sample_ts * interval '1 second' <= p_timestamp
    ORDER BY sample_ts DESC
    LIMIT 1;

    SELECT sample_ts,
           pgfr_record.epoch() + sample_ts * interval '1 second'
    INTO   v_sample_ts_after, v_captured_after
    FROM   pgfr_record.activity_samples
    WHERE  pgfr_record.epoch() + sample_ts * interval '1 second' >= p_timestamp
    ORDER BY sample_ts ASC
    LIMIT 1;

    IF v_sample_ts_before IS NOT NULL AND v_sample_ts_after IS NOT NULL THEN
        v_sample_gap_secs := v_sample_ts_after - v_sample_ts_before;
    END IF;

    -- ==========================================================================
    -- STEP 3: Interpolate snapshot metrics
    -- ==========================================================================
    IF v_snap_before IS NOT NULL AND v_snap_after IS NOT NULL THEN
        v_est_active := pgfr_record._interpolate_metric(
            v_snap_before.connections_active::NUMERIC,
            v_snap_before.captured_at,
            v_snap_after.connections_active::NUMERIC,
            v_snap_after.captured_at,
            p_timestamp
        );

        v_est_total := pgfr_record._interpolate_metric(
            v_snap_before.connections_total::NUMERIC,
            v_snap_before.captured_at,
            v_snap_after.connections_total::NUMERIC,
            v_snap_after.captured_at,
            p_timestamp
        );

        -- Calculate transaction rate delta
        IF v_snap_gap_secs > 0 AND
           v_snap_before.xact_commit IS NOT NULL AND
           v_snap_after.xact_commit IS NOT NULL THEN
            v_est_xact_rate := round(
                ((v_snap_after.xact_commit - v_snap_before.xact_commit) +
                 (v_snap_after.xact_rollback - v_snap_before.xact_rollback))::NUMERIC / v_snap_gap_secs,
                1
            );
        END IF;

        -- Calculate buffer hit ratio
        IF v_snap_after.blks_hit IS NOT NULL AND
           v_snap_after.blks_read IS NOT NULL AND
           (v_snap_after.blks_hit + v_snap_after.blks_read) > 0 THEN
            v_est_hit_ratio := round(
                v_snap_after.blks_hit::NUMERIC /
                NULLIF(v_snap_after.blks_hit + v_snap_after.blks_read, 0) * 100,
                2
            );
        END IF;
    ELSIF v_snap_before IS NOT NULL THEN
        -- Only have before snapshot - use its values
        v_est_active := v_snap_before.connections_active;
        v_est_total := v_snap_before.connections_total;
        v_notes := array_append(v_notes, 'No snapshot after target time - using last known values');
    ELSIF v_snap_after IS NOT NULL THEN
        -- Only have after snapshot - use its values
        v_est_active := v_snap_after.connections_active;
        v_est_total := v_snap_after.connections_total;
        v_notes := array_append(v_notes, 'No snapshot before target time - using next known values');
    ELSE
        v_notes := array_append(v_notes, 'No snapshots found in range');
    END IF;

    -- ==========================================================================
    -- STEP 4: Collect exact-timestamp events from activity samples
    -- ==========================================================================

    -- Check for checkpoint event near target time
    IF v_snap_before IS NOT NULL AND v_snap_before.checkpoint_time IS NOT NULL THEN
        IF v_snap_before.checkpoint_time BETWEEN v_window_start AND v_window_end THEN
            v_event := jsonb_build_object(
                'type', 'checkpoint',
                'time', v_snap_before.checkpoint_time,
                'offset_secs', EXTRACT(EPOCH FROM (v_snap_before.checkpoint_time - p_timestamp))::INTEGER
            );
            v_events := v_events || v_event;
            v_notes := array_append(v_notes, format('Checkpoint at %s provides anchor',
                to_char(v_snap_before.checkpoint_time, 'HH24:MI:SS')));
        END IF;
    END IF;

    -- Check for archiver activity
    IF v_snap_before IS NOT NULL AND v_snap_before.last_archived_time IS NOT NULL THEN
        IF v_snap_before.last_archived_time BETWEEN v_window_start AND v_window_end THEN
            v_event := jsonb_build_object(
                'type', 'wal_archived',
                'time', v_snap_before.last_archived_time,
                'offset_secs', EXTRACT(EPOCH FROM (v_snap_before.last_archived_time - p_timestamp))::INTEGER,
                'wal_file', v_snap_before.last_archived_wal
            );
            v_events := v_events || v_event;
        END IF;
    END IF;

    -- Check for archiver failure
    IF v_snap_before IS NOT NULL AND v_snap_before.last_failed_time IS NOT NULL THEN
        IF v_snap_before.last_failed_time BETWEEN v_window_start AND v_window_end THEN
            v_event := jsonb_build_object(
                'type', 'archive_failed',
                'time', v_snap_before.last_failed_time,
                'offset_secs', EXTRACT(EPOCH FROM (v_snap_before.last_failed_time - p_timestamp))::INTEGER,
                'wal_file', v_snap_before.last_failed_wal
            );
            v_events := v_events || v_event;
            v_recs := array_append(v_recs, 'Investigate WAL archiving failure');
        END IF;
    END IF;

    -- ==========================================================================
    -- STEP 5: Analyze activity from the v2 ring (activity_samples)
    -- ==========================================================================
    IF v_sample_ts_before IS NOT NULL THEN
        SELECT count(*) FILTER (WHERE a.state = 'active'),
               count(*) FILTER (WHERE a.state = 'active')
        INTO v_sessions, v_sessions
        FROM pgfr_record.activity_samples a
        WHERE a.sample_ts = v_sample_ts_before
          AND a.pid IS NOT NULL;

        SELECT count(*),
               max(extract(epoch from (v_captured_before - a.query_start)))
        INTO v_long_running, v_longest_secs
        FROM pgfr_record.activity_samples a
        WHERE a.sample_ts = v_sample_ts_before
          AND a.pid IS NOT NULL
          AND a.state = 'active'
          AND a.query_start IS NOT NULL
          AND a.query_start < v_captured_before - interval '60 seconds';

        FOR v_event IN
            SELECT jsonb_build_object(
                'type', 'query_started',
                'time', a.query_start,
                'offset_secs', extract(epoch from (a.query_start - p_timestamp))::integer,
                'pid', a.pid,
                'user', a.usename,
                'query_preview', a.query_preview
            )
            FROM pgfr_record.activity_samples a
            WHERE a.sample_ts = v_sample_ts_before
              AND a.pid IS NOT NULL
              AND a.query_start BETWEEN v_window_start AND v_window_end
            ORDER BY a.query_start
            LIMIT 10
        LOOP
            v_events := v_events || v_event;
        END LOOP;

        FOR v_event IN
            SELECT jsonb_build_object(
                'type', 'transaction_started',
                'time', a.xact_start,
                'offset_secs', extract(epoch from (a.xact_start - p_timestamp))::integer,
                'pid', a.pid,
                'user', a.usename
            )
            FROM pgfr_record.activity_samples a
            WHERE a.sample_ts = v_sample_ts_before
              AND a.pid IS NOT NULL
              AND a.xact_start BETWEEN v_window_start AND v_window_end
              AND a.xact_start IS DISTINCT FROM a.query_start
            ORDER BY a.xact_start
            LIMIT 10
        LOOP
            v_events := v_events || v_event;
        END LOOP;
    END IF;

    -- ==========================================================================
    -- STEP 6: Analyze lock contention from the v2 ring
    -- ==========================================================================
    IF v_sample_ts_before IS NOT NULL THEN
        SELECT count(*) > 0, count(*)
        INTO v_lock_detected, v_blocked
        FROM pgfr_record.lock_samples ls
        WHERE ls.sample_ts = v_sample_ts_before
          AND ls.blocked_pid IS NOT NULL;

        IF v_blocked > 0 THEN
            v_recs := array_append(v_recs, format('Investigate %s blocked sessions', v_blocked));
        END IF;
    END IF;

    -- ==========================================================================
    -- STEP 7: Analyze wait events from the v2 ring (decode via wait_event_map)
    -- ==========================================================================
    IF v_sample_ts_before IS NOT NULL THEN
        SELECT jsonb_agg(w ORDER BY w->>'count' DESC)
        INTO v_waits
        FROM (
            SELECT jsonb_build_object(
                'wait_event_type', wem.type,
                'wait_event', wem.event,
                'count', abs(ws.data[i + 1])
            ) AS w
            FROM pgfr_record.wait_samples ws
            CROSS JOIN generate_subscripts(ws.data, 1) AS i
            JOIN pgfr_record.wait_event_map wem ON wem.id = abs(ws.data[i])::smallint
            WHERE ws.data[i] < 0
              AND ws.sample_ts = v_sample_ts_before
            ORDER BY abs(ws.data[i + 1]) DESC NULLS LAST
            LIMIT 5
        ) sub;
    END IF;

    -- ==========================================================================
    -- STEP 8: Calculate confidence score
    -- ==========================================================================
    -- Base score on sample gap
    IF v_sample_gap_secs IS NOT NULL THEN
        IF v_sample_gap_secs < 60 THEN
            v_confidence_score := 0.9;
        ELSIF v_sample_gap_secs < 300 THEN
            v_confidence_score := 0.7 + (0.2 * (300 - v_sample_gap_secs) / 240);
        ELSIF v_sample_gap_secs < 600 THEN
            v_confidence_score := 0.5 + (0.2 * (600 - v_sample_gap_secs) / 300);
        ELSE
            v_confidence_score := 0.3;
        END IF;

        v_notes := array_append(v_notes, format('Sample gap is %s seconds', v_sample_gap_secs::INTEGER));
    ELSE
        v_confidence_score := 0.2;
        v_notes := array_append(v_notes, 'No sample data in ring buffer');
    END IF;

    -- Bonus for exact-timestamp events
    IF jsonb_array_length(v_events) > 0 THEN
        v_confidence_score := LEAST(1.0, v_confidence_score + 0.1);
        v_notes := array_append(v_notes, format('%s exact-timestamp events found', jsonb_array_length(v_events)));
    END IF;

    -- Bonus for target close to sample
    IF v_sample_ts_before IS NOT NULL THEN
        DECLARE
            v_closest_gap NUMERIC;
        BEGIN
            v_closest_gap := LEAST(
                ABS(EXTRACT(EPOCH FROM (p_timestamp - v_captured_before))),
                COALESCE(ABS(EXTRACT(EPOCH FROM (p_timestamp - v_captured_after))), 999999)
            );
            IF v_closest_gap < 30 THEN
                v_confidence_score := LEAST(1.0, v_confidence_score + 0.05);
            END IF;
        END;
    END IF;

    -- Determine confidence level
    IF v_confidence_score >= 0.8 THEN
        v_confidence_level := 'high';
    ELSIF v_confidence_score >= 0.6 THEN
        v_confidence_level := 'medium';
    ELSIF v_confidence_score >= 0.4 THEN
        v_confidence_level := 'low';
    ELSE
        v_confidence_level := 'very_low';
    END IF;

    -- ==========================================================================
    -- STEP 9: Generate recommendations
    -- ==========================================================================
    IF v_long_running > 0 THEN
        v_recs := array_append(v_recs, format('Review %s long-running queries (longest: %s sec)',
            v_long_running, round(v_longest_secs)));
    END IF;

    IF v_est_hit_ratio IS NOT NULL AND v_est_hit_ratio < 95 THEN
        v_recs := array_append(v_recs, format('Buffer hit ratio low (%s%%) - consider increasing shared_buffers',
            v_est_hit_ratio));
    END IF;

    -- Check for checkpoint impact
    FOR v_event IN SELECT * FROM jsonb_array_elements(v_events)
    LOOP
        IF v_event->>'type' = 'checkpoint' THEN
            v_recs := array_append(v_recs, 'Review checkpoint impact on performance');
        END IF;
    END LOOP;

    IF array_length(v_recs, 1) IS NULL THEN
        v_recs := array_append(v_recs, 'No immediate concerns detected');
    END IF;

    -- ==========================================================================
    -- RETURN RESULTS
    -- ==========================================================================
    RETURN QUERY SELECT
        p_timestamp,
        v_captured_before,
        v_captured_after,
        v_snap_before.captured_at,
        v_snap_after.captured_at,
        v_est_active,
        v_est_total,
        v_est_xact_rate,
        v_est_hit_ratio,
        COALESCE(v_events, '[]'::jsonb),
        v_sessions,
        COALESCE(v_long_running, 0),
        COALESCE(v_longest_secs, 0),
        v_lock_detected,
        v_blocked,
        COALESCE(v_waits, '[]'::jsonb),
        v_confidence_level,
        round(v_confidence_score, 2),
        v_notes,
        v_recs;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.what_happened_at IS
'Time-travel debugging: Forensic analysis of system state at any timestamp. Interpolates between samples to estimate connections, transaction rates, and buffer hit ratio. Surfaces exact-timestamp events (checkpoints, query starts, transaction starts) and analyzes sessions, locks, and wait events. Returns confidence score (0-1) based on data proximity. Use for incident investigation: SELECT * FROM pgfr_analyze.what_happened_at(''2024-01-15 10:23:47'');

Output columns:
  requested_time: [dimension] [timestamp] The p_timestamp argument echoed back: the instant being reconstructed.
  sample_before: [dimension] [timestamp] Capture time of the nearest activity_samples ring tick at or before the requested time; NULL when the ring holds no earlier tick.
  sample_after: [dimension] [timestamp] Capture time of the nearest activity_samples ring tick at or after the requested time; NULL when the ring holds no later tick.
  snapshot_before: [dimension] [timestamp] captured_at of the nearest snapshots row at or before the requested time.
  snapshot_after: [dimension] [timestamp] captured_at of the nearest snapshots row at or after the requested time.
  est_connections_active: [derived] [count] Estimated active connections at the requested time: linear interpolation of the connections_active gauge between the bracketing snapshots (falls back to the single available snapshot value when only one side exists). An estimate, not a measurement; spikes between snapshots are invisible.
  est_connections_total: [derived] [count] Estimated total connections at the requested time: linear interpolation of the connections_total gauge between the bracketing snapshots, with the same single-snapshot fallback. An estimate, not a measurement.
  est_xact_rate: [derived] [count/s] [interval-mean] Estimated transaction rate around the requested time: xact_commit plus xact_rollback differenced between the bracketing snapshots and divided by their gap. It is the mean rate over that whole snapshot interval attributed to the requested instant, never an instantaneous rate.
  est_blks_hit_ratio: [derived] [percent] Buffer cache hit ratio computed from the after-side snapshot cumulative counters: blks_hit as a percent of blks_hit plus blks_read since statistics reset (lifetime totals, not a delta over the window), so it moves slowly and is only loosely tied to the requested instant.
  events: [derived] [json] Array of exact-timestamp events reconstructed within the context window: checkpoint, WAL archived, and archive failed times from the before-side snapshot, plus up to 10 query starts and 10 transaction starts read from the nearest-before activity sample. Only sessions still visible at that sample tick appear; short-lived sessions that ended before the tick are missed.
  sessions_active: [point-sample] [count] Number of sessions in state active in the nearest-before activity ring sample: a point-in-time reading as of that tick, not an average over the window.
  long_running_queries: [point-sample] [count] Number of active sessions in the nearest-before activity sample whose query_start was more than 60 seconds before the tick, as of the sample instant; biased toward long-running queries by construction.
  longest_query_secs: [point-sample] [seconds] Longest elapsed runtime among those long-running queries, measured from query_start to the sample capture time, as of the sample instant.
  lock_contention_detected: [derived] [boolean] Flag set when the nearest-before lock_samples tick contains any blocked session row; computed from a single point sample, so false does not rule out contention between ticks.
  blocked_sessions: [point-sample] [count] Number of blocked-session rows in lock_samples at the nearest-before tick: sessions observed blocked at that instant, biased against waits shorter than the sampling interval.
  top_wait_events: [point-sample] [json] Top 5 wait events with waiter counts, decoded from the wait_samples ring at the nearest-before tick; waiter counts are as of that instant and estimate time-in-state, never event frequency.
  confidence: [derived] [text] Qualitative confidence level (high, medium, low, very_low) bucketed from confidence_score.
  confidence_score: [derived] [fraction] Confidence in the reconstruction on a 0-1 scale: a heuristic computed from the gap between bracketing ring samples plus bonuses for exact-timestamp events and proximity to a sample; not a calibrated probability.
  data_quality_notes: [derived] [text] Notes on gaps, fallbacks, and timing anchors encountered during reconstruction (sample gap size, missing snapshots, checkpoint anchors).
  recommendations: [derived] [text] Heuristic follow-up suggestions triggered by blocked sessions, long-running queries, low hit ratio, checkpoint proximity, or archive failures.';


-- Timeline reconstruction for incident analysis
-- Merges events from multiple sources into a unified, chronological timeline
-- Input: Start and end timestamps for the incident window
-- Output: Ordered timeline of events with type, description, and details
CREATE OR REPLACE FUNCTION pgfr_analyze.incident_timeline(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    event_time TIMESTAMPTZ,
    event_type TEXT,
    description TEXT,
    details JSONB
)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    WITH all_events AS (
        -- Checkpoint events from snapshots
        SELECT DISTINCT
            s.checkpoint_time AS event_time,
            'checkpoint'::TEXT AS event_type,
            format('Checkpoint completed (LSN: %s)', s.checkpoint_lsn::TEXT) AS description,
            jsonb_build_object(
                'checkpoint_lsn', s.checkpoint_lsn::TEXT,
                'buffers_written', s.ckpt_buffers,
                'write_time_ms', round(s.ckpt_write_time::NUMERIC, 1),
                'sync_time_ms', round(s.ckpt_sync_time::NUMERIC, 1)
            ) AS details
        FROM pgfr_record.snapshots s
        WHERE s.checkpoint_time BETWEEN p_start_time AND p_end_time
          AND s.checkpoint_time IS NOT NULL

        UNION ALL

        -- WAL archive events
        SELECT DISTINCT
            s.last_archived_time AS event_time,
            'wal_archived'::TEXT AS event_type,
            format('WAL file archived: %s', s.last_archived_wal) AS description,
            jsonb_build_object(
                'wal_file', s.last_archived_wal,
                'archived_count', s.archived_count
            ) AS details
        FROM pgfr_record.snapshots s
        WHERE s.last_archived_time BETWEEN p_start_time AND p_end_time
          AND s.last_archived_time IS NOT NULL

        UNION ALL

        -- WAL archive failures
        SELECT DISTINCT
            s.last_failed_time AS event_time,
            'archive_failed'::TEXT AS event_type,
            format('WAL archive failed: %s', s.last_failed_wal) AS description,
            jsonb_build_object(
                'wal_file', s.last_failed_wal,
                'failed_count', s.failed_count
            ) AS details
        FROM pgfr_record.snapshots s
        WHERE s.last_failed_time BETWEEN p_start_time AND p_end_time
          AND s.last_failed_time IS NOT NULL

        UNION ALL

        -- Query start events from legacy ring buffer

        -- Query start events from v2 ring
        SELECT
            a.query_start AS event_time,
            'query_started'::TEXT AS event_type,
            format('Query started by %s (pid %s)', COALESCE(a.usename, 'unknown'), a.pid) AS description,
            jsonb_build_object(
                'pid', a.pid,
                'user', a.usename,
                'application', a.application_name,
                'client_addr', a.client_addr::TEXT,
                'query_preview', a.query_preview
            ) AS details
        FROM pgfr_record.activity_samples a
        WHERE a.query_start BETWEEN p_start_time AND p_end_time
          AND a.query_start IS NOT NULL
          AND a.pid IS NOT NULL

        UNION ALL

        -- Transaction start events from legacy ring buffer

        -- Transaction start events from v2 ring
        SELECT
            a.xact_start AS event_time,
            'transaction_started'::TEXT AS event_type,
            format('Transaction started by %s (pid %s)', COALESCE(a.usename, 'unknown'), a.pid) AS description,
            jsonb_build_object(
                'pid', a.pid,
                'user', a.usename,
                'application', a.application_name
            ) AS details
        FROM pgfr_record.activity_samples a
        WHERE a.xact_start BETWEEN p_start_time AND p_end_time
          AND a.xact_start IS NOT NULL
          AND a.pid IS NOT NULL
          AND a.xact_start IS DISTINCT FROM a.query_start

        UNION ALL

        -- Backend start events (new connections) from legacy ring

        -- Backend start events from v2 ring
        SELECT
            a.backend_start AS event_time,
            'connection_opened'::TEXT AS event_type,
            format('Connection opened by %s from %s', COALESCE(a.usename, 'unknown'),
                   COALESCE(a.client_addr::TEXT, 'local')) AS description,
            jsonb_build_object(
                'pid', a.pid,
                'user', a.usename,
                'application', a.application_name,
                'client_addr', a.client_addr::TEXT,
                'backend_type', a.backend_type
            ) AS details
        FROM pgfr_record.activity_samples a
        WHERE a.backend_start BETWEEN p_start_time AND p_end_time
          AND a.backend_start IS NOT NULL
          AND a.pid IS NOT NULL

        UNION ALL

        -- Lock contention events from legacy ring

        -- Lock contention events from v2 ring
        SELECT
            pgfr_record.epoch() + ls.sample_ts * interval '1 second' AS event_time,
            'lock_contention'::TEXT AS event_type,
            format('Session %s blocked by %s on %s lock',
                   ls.blocked_pid, ls.blocking_pid,
                   coalesce(ltm.lock_type, ls.lock_type::text)) AS description,
            jsonb_build_object(
                'blocked_pid', ls.blocked_pid,
                'blocking_pid', ls.blocking_pid,
                'lock_type', coalesce(ltm.lock_type, ls.lock_type::text),
                'duration_s', ls.blocked_duration_s
            ) AS details
        FROM pgfr_record.lock_samples ls
        LEFT JOIN pgfr_record.lock_type_map ltm ON ltm.id = ls.lock_type
        WHERE pgfr_record.epoch() + ls.sample_ts * interval '1 second'
              BETWEEN p_start_time AND p_end_time
          AND ls.blocked_pid IS NOT NULL

        UNION ALL

        -- Wait event spikes (v2): one row per (database, wait group) per tick
        -- in wait_samples; we surface samples where waiter_count >= 3.
        -- wait_event identity comes from wait_event_map.
        SELECT
            pgfr_record.epoch() + ws.sample_ts * interval '1 second' AS event_time,
            'wait_spike'::TEXT AS event_type,
            format('Wait spike: %s/%s (%s concurrent)',
                   wem.type, wem.event, abs(ws.data[i + 1])) AS description,
            jsonb_build_object(
                'wait_event_type', wem.type,
                'wait_event',      wem.event,
                'max_concurrent',  abs(ws.data[i + 1]),
                'active_count',    ws.active_count
            ) AS details
        FROM pgfr_record.wait_samples ws
        CROSS JOIN generate_subscripts(ws.data, 1) AS i
        JOIN pgfr_record.wait_event_map wem ON wem.id = abs(ws.data[i])::smallint
        WHERE ws.data[i] < 0
          AND pgfr_record.epoch() + ws.sample_ts * interval '1 second'
              BETWEEN p_start_time AND p_end_time
          AND abs(ws.data[i + 1]) >= 3  -- Only show significant waits

        UNION ALL

        -- Snapshot captures (system state markers)
        SELECT
            s.captured_at AS event_time,
            'snapshot'::TEXT AS event_type,
            format('System snapshot: %s active connections, %s TPS',
                   s.connections_active,
                   CASE WHEN lag(s.xact_commit) OVER (ORDER BY s.captured_at) IS NOT NULL
                        THEN round((s.xact_commit - lag(s.xact_commit) OVER (ORDER BY s.captured_at))::NUMERIC /
                                   NULLIF(EXTRACT(EPOCH FROM (s.captured_at - lag(s.captured_at) OVER (ORDER BY s.captured_at))), 0), 1)
                        ELSE NULL
                   END) AS description,
            jsonb_build_object(
                'connections_active', s.connections_active,
                'connections_total', s.connections_total,
                'xact_commit', s.xact_commit,
                'blks_hit', s.blks_hit,
                'blks_read', s.blks_read,
                'temp_bytes', s.temp_bytes
            ) AS details
        FROM pgfr_record.snapshots s
        WHERE s.captured_at BETWEEN p_start_time AND p_end_time
    )
    SELECT ae.event_time, ae.event_type, ae.description, ae.details
    FROM all_events ae
    WHERE ae.event_time IS NOT NULL
    ORDER BY ae.event_time;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.incident_timeline IS
'Reconstructs a unified timeline for incident analysis by merging events from multiple sources: checkpoints, WAL archiving, query/transaction starts, connection opens, lock contention, wait spikes, and snapshots. Returns chronologically ordered events with type, description, and JSON details. Use for incident review: SELECT * FROM pgfr_analyze.incident_timeline(now() - interval ''2 hours'', now() - interval ''1 hour'');

Output columns:
  event_time: [dimension] [timestamp] When the event occurred: exact recorded timestamps for checkpoints, WAL archive events, query/transaction/backend starts, and snapshot captures, but the sample tick time for lock_contention and wait_spike rows, whose resolution is the sampling cadence.
  event_type: [dimension] [text] Event kind: checkpoint, wal_archived, archive_failed, query_started, transaction_started, connection_opened, lock_contention, wait_spike, or snapshot. Sample-sourced kinds (lock_contention, wait_spike) reflect state observed at ticks, not every occurrence; wait_spike rows only appear when a tick shows 3 or more concurrent waiters on an event.
  description: [derived] [text] Human-readable one-line summary formatted from the source row (the snapshot row TPS figure is a mean rate between consecutive snapshots).
  details: [derived] [json] Event-specific attributes copied from the source row: identity fields (pid, user, application, WAL file), gauge and counter values for snapshot and checkpoint events, and point-sample counts for lock and wait events.';


-- Blast Radius Analysis
-- Comprehensive impact assessment of database incidents
-- Answers: "What was the collateral damage from this incident?"
-- Input: Start and end timestamps for the incident window
-- Output: Structured impact assessment including locks, queries, connections, applications
CREATE OR REPLACE FUNCTION pgfr_analyze.blast_radius(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    -- Time window
    incident_start TIMESTAMPTZ,
    incident_end TIMESTAMPTZ,
    duration_seconds NUMERIC,

    -- Lock impact
    blocked_sessions_total INTEGER,
    blocked_sessions_max_concurrent INTEGER,
    max_block_duration INTERVAL,
    avg_block_duration INTERVAL,
    lock_types JSONB,

    -- Query degradation
    degraded_queries_count INTEGER,
    degraded_queries JSONB,

    -- Connection impact
    connections_before INTEGER,
    connections_during_avg INTEGER,
    connections_during_max INTEGER,
    connection_increase_pct NUMERIC,

    -- Application impact
    affected_applications JSONB,

    -- Wait event impact
    top_wait_events JSONB,

    -- Transaction throughput
    tps_before NUMERIC,
    tps_during NUMERIC,
    tps_change_pct NUMERIC,

    -- Summary
    severity TEXT,
    impact_summary TEXT[],
    recommendations TEXT[]
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_duration INTERVAL;
    v_baseline_start TIMESTAMPTZ;
    v_baseline_end TIMESTAMPTZ;

    -- Lock impact variables
    v_blocked_total INTEGER := 0;
    v_blocked_max_concurrent INTEGER := 0;
    v_max_block_duration INTERVAL;
    v_avg_block_duration INTERVAL;
    v_lock_types JSONB := '[]'::jsonb;

    -- Query degradation variables
    v_degraded_count INTEGER := 0;
    v_degraded_queries JSONB := '[]'::jsonb;

    -- Connection variables
    v_conn_before INTEGER := 0;
    v_conn_during_avg INTEGER := 0;
    v_conn_during_max INTEGER := 0;
    v_conn_increase_pct NUMERIC := 0;

    -- Application impact
    v_affected_apps JSONB := '[]'::jsonb;

    -- Wait events
    v_top_waits JSONB := '[]'::jsonb;

    -- Throughput variables
    v_tps_before NUMERIC := 0;
    v_tps_during NUMERIC := 0;
    v_tps_change_pct NUMERIC := 0;

    -- Severity calculation
    v_severity TEXT := 'low';
    v_impact_summary TEXT[] := ARRAY[]::TEXT[];
    v_recommendations TEXT[] := ARRAY[]::TEXT[];

    -- Severity scores
    v_lock_severity INTEGER := 0;
    v_duration_severity INTEGER := 0;
    v_conn_severity INTEGER := 0;
    v_tps_severity INTEGER := 0;
    v_query_severity INTEGER := 0;
BEGIN
    -- Calculate duration and baseline period
    v_duration := p_end_time - p_start_time;
    v_baseline_start := p_start_time - v_duration;
    v_baseline_end := p_start_time;

    -- =========================================================================
    -- Lock Impact Analysis
    -- =========================================================================

    -- Total blocked sessions and durations from v2 ring
    SELECT
        COUNT(DISTINCT ls.blocked_pid),
        MAX(ls.blocked_duration_s * interval '1 second'),
        AVG(ls.blocked_duration_s * interval '1 second')
    INTO v_blocked_total, v_max_block_duration, v_avg_block_duration
    FROM pgfr_record.lock_samples ls
    WHERE pgfr_record.epoch() + ls.sample_ts * interval '1 second'
          BETWEEN p_start_time AND p_end_time
      AND ls.blocked_pid IS NOT NULL;

    -- (Legacy lock_samples_archive fallback retired alongside the archive
    -- tables; v2 lock_samples is the single source of truth.)

    v_blocked_total := COALESCE(v_blocked_total, 0);

    -- Max concurrent blocked sessions (per sample) from v2 ring
    SELECT COALESCE(MAX(blocked_count), 0)
    INTO v_blocked_max_concurrent
    FROM (
        SELECT ls.sample_ts, COUNT(DISTINCT ls.blocked_pid) AS blocked_count
        FROM pgfr_record.lock_samples ls
        WHERE pgfr_record.epoch() + ls.sample_ts * interval '1 second'
              BETWEEN p_start_time AND p_end_time
          AND ls.blocked_pid IS NOT NULL
        GROUP BY ls.sample_ts
    ) per_sample;

    -- Lock types breakdown from v2 ring (decoded via lock_type_map)
    SELECT COALESCE(jsonb_agg(jsonb_build_object('type', lock_type, 'count', cnt) ORDER BY cnt DESC), '[]'::jsonb)
    INTO v_lock_types
    FROM (
        SELECT coalesce(ltm.lock_type, ls.lock_type::text) AS lock_type, COUNT(*) AS cnt
        FROM pgfr_record.lock_samples ls
        LEFT JOIN pgfr_record.lock_type_map ltm ON ltm.id = ls.lock_type
        WHERE pgfr_record.epoch() + ls.sample_ts * interval '1 second'
              BETWEEN p_start_time AND p_end_time
          AND ls.blocked_pid IS NOT NULL
        GROUP BY coalesce(ltm.lock_type, ls.lock_type::text)
        ORDER BY cnt DESC
        LIMIT 10
    ) lt;

    -- =========================================================================
    -- Query Degradation Analysis
    -- =========================================================================

    WITH baseline AS (
        SELECT
            ss.queryid,
            left(ss.query_preview, 80) AS query_preview,
            AVG(ss.mean_exec_time) AS baseline_ms
        FROM pgfr_record.statement_snapshots ss
        JOIN pgfr_record.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at BETWEEN v_baseline_start AND v_baseline_end
          AND ss.mean_exec_time IS NOT NULL
          AND ss.mean_exec_time > 0
        GROUP BY ss.queryid, left(ss.query_preview, 80)
        HAVING COUNT(*) >= 1
    ),
    during AS (
        SELECT
            ss.queryid,
            AVG(ss.mean_exec_time) AS during_ms
        FROM pgfr_record.statement_snapshots ss
        JOIN pgfr_record.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at BETWEEN p_start_time AND p_end_time
          AND ss.mean_exec_time IS NOT NULL
          AND ss.mean_exec_time > 0
        GROUP BY ss.queryid
        HAVING COUNT(*) >= 1
    ),
    degraded AS (
        SELECT
            b.queryid,
            b.query_preview,
            round(b.baseline_ms::numeric, 2) AS baseline_ms,
            round(d.during_ms::numeric, 2) AS during_ms,
            round((100.0 * (d.during_ms - b.baseline_ms) / NULLIF(b.baseline_ms, 0))::numeric, 1) AS slowdown_pct
        FROM baseline b
        JOIN during d ON d.queryid = b.queryid
        WHERE d.during_ms > b.baseline_ms * 1.5  -- 50%+ slower
        ORDER BY (d.during_ms - b.baseline_ms) DESC
        LIMIT 10
    )
    SELECT
        COUNT(*)::integer,
        COALESCE(jsonb_agg(jsonb_build_object(
            'queryid', queryid,
            'query_preview', query_preview,
            'baseline_ms', baseline_ms,
            'during_ms', during_ms,
            'slowdown_pct', slowdown_pct
        )), '[]'::jsonb)
    INTO v_degraded_count, v_degraded_queries
    FROM degraded;

    v_degraded_count := COALESCE(v_degraded_count, 0);

    -- =========================================================================
    -- Connection Impact Analysis
    -- =========================================================================

    -- Baseline connections (average before incident)
    SELECT COALESCE(AVG(connections_total), 0)::integer
    INTO v_conn_before
    FROM pgfr_record.snapshots
    WHERE captured_at BETWEEN v_baseline_start AND v_baseline_end;

    -- During incident connections
    SELECT
        COALESCE(AVG(connections_total), 0)::integer,
        COALESCE(MAX(connections_total), 0)::integer
    INTO v_conn_during_avg, v_conn_during_max
    FROM pgfr_record.snapshots
    WHERE captured_at BETWEEN p_start_time AND p_end_time;

    -- Connection increase percentage
    IF v_conn_before > 0 THEN
        v_conn_increase_pct := round(100.0 * (v_conn_during_avg - v_conn_before) / v_conn_before, 1);
    END IF;

    -- =========================================================================
    -- Application Impact Analysis
    -- =========================================================================

    -- v2 lock_samples doesn't store the blocked_app field; surface as 'unknown'.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'app_name', app,
        'blocked_count', blocked_count,
        'max_wait', max_wait
    ) ORDER BY blocked_count DESC), '[]'::jsonb)
    INTO v_affected_apps
    FROM (
        SELECT
            'unknown' AS app,
            COUNT(DISTINCT ls.blocked_pid) AS blocked_count,
            MAX(ls.blocked_duration_s * interval '1 second') AS max_wait
        FROM pgfr_record.lock_samples ls
        WHERE pgfr_record.epoch() + ls.sample_ts * interval '1 second'
              BETWEEN p_start_time AND p_end_time
          AND ls.blocked_pid IS NOT NULL
        GROUP BY 1
        ORDER BY blocked_count DESC
        LIMIT 10
    ) apps;

    -- =========================================================================
    -- Wait Event Analysis
    -- =========================================================================

    WITH baseline_waits AS (
        SELECT wait_event_type, wait_event, SUM(total_count) AS total_count
        FROM (
            -- legacy ring
            -- v2 ring: decode integer array
            SELECT wem.type AS wait_event_type, wem.event AS wait_event,
                   abs(ws.data[i + 1])::bigint AS total_count
            FROM pgfr_record.wait_samples ws
            cross join generate_subscripts(ws.data, 1) AS i
            join pgfr_record.wait_event_map wem ON wem.id = abs(ws.data[i])::smallint
            WHERE ws.data[i] < 0
              AND pgfr_record.epoch() + ws.sample_ts * interval '1 second'
                  BETWEEN v_baseline_start AND v_baseline_end
        ) combined
        GROUP BY wait_event_type, wait_event
    ),
    during_waits AS (
        SELECT wait_event_type, wait_event, SUM(total_count) AS total_count
        FROM (
            -- legacy ring
            -- v2 ring: decode integer array
            SELECT wem.type AS wait_event_type, wem.event AS wait_event,
                   abs(ws.data[i + 1])::bigint AS total_count
            FROM pgfr_record.wait_samples ws
            cross join generate_subscripts(ws.data, 1) AS i
            join pgfr_record.wait_event_map wem ON wem.id = abs(ws.data[i])::smallint
            WHERE ws.data[i] < 0
              AND pgfr_record.epoch() + ws.sample_ts * interval '1 second'
                  BETWEEN p_start_time AND p_end_time
        ) combined
        GROUP BY wait_event_type, wait_event
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'wait_type', d.wait_event_type,
        'wait_event', d.wait_event,
        'total_count', d.total_count,
        'pct_increase', CASE
            WHEN COALESCE(b.total_count, 0) > 0
            THEN round(100.0 * (d.total_count - COALESCE(b.total_count, 0)) / b.total_count, 1)
            ELSE NULL
        END
    ) ORDER BY d.total_count DESC), '[]'::jsonb)
    INTO v_top_waits
    FROM during_waits d
    LEFT JOIN baseline_waits b ON b.wait_event_type = d.wait_event_type
                               AND b.wait_event = d.wait_event
    WHERE d.total_count > 0
    LIMIT 10;

    -- =========================================================================
    -- Transaction Throughput Analysis
    -- =========================================================================

    -- Calculate TPS before incident
    WITH baseline_tps AS (
        SELECT
            xact_commit,
            captured_at,
            LAG(xact_commit) OVER (ORDER BY captured_at) AS prev_commit,
            LAG(captured_at) OVER (ORDER BY captured_at) AS prev_time
        FROM pgfr_record.snapshots
        WHERE captured_at BETWEEN v_baseline_start AND v_baseline_end
    )
    SELECT COALESCE(AVG(
        CASE
            WHEN prev_commit IS NOT NULL AND prev_time IS NOT NULL
                 AND EXTRACT(EPOCH FROM (captured_at - prev_time)) > 0
            THEN (xact_commit - prev_commit)::numeric / EXTRACT(EPOCH FROM (captured_at - prev_time))
            ELSE NULL
        END
    ), 0)
    INTO v_tps_before
    FROM baseline_tps;

    -- Calculate TPS during incident
    WITH during_tps AS (
        SELECT
            xact_commit,
            captured_at,
            LAG(xact_commit) OVER (ORDER BY captured_at) AS prev_commit,
            LAG(captured_at) OVER (ORDER BY captured_at) AS prev_time
        FROM pgfr_record.snapshots
        WHERE captured_at BETWEEN p_start_time AND p_end_time
    )
    SELECT COALESCE(AVG(
        CASE
            WHEN prev_commit IS NOT NULL AND prev_time IS NOT NULL
                 AND EXTRACT(EPOCH FROM (captured_at - prev_time)) > 0
            THEN (xact_commit - prev_commit)::numeric / EXTRACT(EPOCH FROM (captured_at - prev_time))
            ELSE NULL
        END
    ), 0)
    INTO v_tps_during
    FROM during_tps;

    -- TPS change percentage
    IF v_tps_before > 0 THEN
        v_tps_change_pct := round(100.0 * (v_tps_during - v_tps_before) / v_tps_before, 1);
    END IF;

    -- =========================================================================
    -- Severity Classification
    -- =========================================================================

    -- Blocked sessions severity: 1-5=low, 6-20=medium, 21-50=high, >50=critical
    v_lock_severity := CASE
        WHEN v_blocked_total > 50 THEN 4
        WHEN v_blocked_total > 20 THEN 3
        WHEN v_blocked_total > 5 THEN 2
        WHEN v_blocked_total > 0 THEN 1
        ELSE 0
    END;

    -- Block duration severity: <10s=low, 10-60s=medium, 1-5min=high, >5min=critical
    v_duration_severity := CASE
        WHEN v_max_block_duration > interval '5 minutes' THEN 4
        WHEN v_max_block_duration > interval '1 minute' THEN 3
        WHEN v_max_block_duration > interval '10 seconds' THEN 2
        WHEN v_max_block_duration IS NOT NULL THEN 1
        ELSE 0
    END;

    -- Connection increase severity: <25%=low, 25-50%=medium, 50-100%=high, >100%=critical
    v_conn_severity := CASE
        WHEN v_conn_increase_pct > 100 THEN 4
        WHEN v_conn_increase_pct > 50 THEN 3
        WHEN v_conn_increase_pct > 25 THEN 2
        WHEN v_conn_increase_pct > 0 THEN 1
        ELSE 0
    END;

    -- TPS decrease severity: <10%=low, 10-25%=medium, 25-50%=high, >50%=critical
    v_tps_severity := CASE
        WHEN v_tps_change_pct < -50 THEN 4
        WHEN v_tps_change_pct < -25 THEN 3
        WHEN v_tps_change_pct < -10 THEN 2
        WHEN v_tps_change_pct < 0 THEN 1
        ELSE 0
    END;

    -- Degraded queries severity: 1-3=low, 4-10=medium, 11-25=high, >25=critical
    v_query_severity := CASE
        WHEN v_degraded_count > 25 THEN 4
        WHEN v_degraded_count > 10 THEN 3
        WHEN v_degraded_count > 3 THEN 2
        WHEN v_degraded_count > 0 THEN 1
        ELSE 0
    END;

    -- Overall severity = highest individual severity
    v_severity := CASE GREATEST(v_lock_severity, v_duration_severity, v_conn_severity, v_tps_severity, v_query_severity)
        WHEN 4 THEN 'critical'
        WHEN 3 THEN 'high'
        WHEN 2 THEN 'medium'
        WHEN 1 THEN 'low'
        ELSE 'low'
    END;

    -- =========================================================================
    -- Impact Summary
    -- =========================================================================

    IF v_blocked_total > 0 THEN
        v_impact_summary := array_append(v_impact_summary,
            format('%s sessions blocked (max %s)',
                   v_blocked_total,
                   COALESCE(to_char(v_max_block_duration, 'MI"m" SS"s"'), 'unknown')));
    END IF;

    IF v_tps_change_pct < -10 THEN
        v_impact_summary := array_append(v_impact_summary,
            format('TPS dropped %s%%', abs(v_tps_change_pct)::integer));
    END IF;

    IF v_degraded_count > 0 THEN
        v_impact_summary := array_append(v_impact_summary,
            format('%s queries degraded >50%%', v_degraded_count));
    END IF;

    IF v_conn_increase_pct > 25 THEN
        v_impact_summary := array_append(v_impact_summary,
            format('Connections increased %s%%', v_conn_increase_pct::integer));
    END IF;

    IF array_length(v_impact_summary, 1) IS NULL THEN
        v_impact_summary := array_append(v_impact_summary, 'No significant impact detected');
    END IF;

    -- =========================================================================
    -- Recommendations
    -- =========================================================================

    IF v_max_block_duration > interval '1 minute' THEN
        v_recommendations := array_append(v_recommendations,
            'Review the blocking query that held locks for extended duration');
    END IF;

    IF v_blocked_total > 10 THEN
        v_recommendations := array_append(v_recommendations,
            'Consider setting lock_timeout to prevent long waits');
    END IF;

    IF v_conn_increase_pct > 50 THEN
        v_recommendations := array_append(v_recommendations,
            format('Investigate connection pool sizing (reached %s connections)', v_conn_during_max));
    END IF;

    IF v_degraded_count > 3 THEN
        v_recommendations := array_append(v_recommendations,
            format('%s queries showed >50%% degradation - review execution plans', v_degraded_count));
    END IF;

    IF v_tps_change_pct < -25 THEN
        v_recommendations := array_append(v_recommendations,
            'Throughput dropped significantly - analyze root cause of slowdown');
    END IF;

    IF array_length(v_recommendations, 1) IS NULL THEN
        v_recommendations := array_append(v_recommendations, 'No specific recommendations');
    END IF;

    -- =========================================================================
    -- Return Results
    -- =========================================================================

    RETURN QUERY SELECT
        p_start_time,
        p_end_time,
        round(EXTRACT(EPOCH FROM v_duration), 0),
        v_blocked_total,
        v_blocked_max_concurrent,
        v_max_block_duration,
        v_avg_block_duration,
        v_lock_types,
        v_degraded_count,
        v_degraded_queries,
        v_conn_before,
        v_conn_during_avg,
        v_conn_during_max,
        v_conn_increase_pct,
        v_affected_apps,
        v_top_waits,
        round(v_tps_before, 1),
        round(v_tps_during, 1),
        v_tps_change_pct,
        v_severity,
        v_impact_summary,
        v_recommendations;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.blast_radius IS
'Comprehensive blast radius analysis for incident impact assessment. Analyzes lock impact (blocked sessions, duration, types), query degradation (before vs during), connection spike, affected applications, wait events, and transaction throughput. Returns severity classification (low/medium/high/critical) with impact summary and recommendations. Use for incident postmortems: SELECT * FROM pgfr_analyze.blast_radius(''2024-01-15 10:23:00'', ''2024-01-15 10:35:00'');

Output columns:
  incident_start: [dimension] [timestamp] The p_start_time argument echoed back; the baseline window is the equal-length period immediately before it.
  incident_end: [dimension] [timestamp] The p_end_time argument echoed back.
  duration_seconds: [derived] [seconds] Incident window length, p_end_time minus p_start_time, rounded to whole seconds.
  blocked_sessions_total: [point-sample] [count] Distinct blocked_pid values seen in lock_samples ticks within the incident window: it counts sessions observed blocked in at least one sample, not all blocking events; waits shorter than the sampling interval are mostly missed, and a pid blocked repeatedly counts once.
  blocked_sessions_max_concurrent: [point-sample] [count] Largest number of distinct blocked sessions seen in any single lock_samples tick within the window: peak observed concurrency as of that sample instant.
  max_block_duration: [point-sample] [duration] Maximum blocked_duration_s across lock sample rows in the window: the longest a session had already been blocked as of some sample instant; a wait can grow or end unobserved between ticks, so this is a lower bound on the true longest wait.
  avg_block_duration: [point-sample] [duration] Mean blocked_duration_s across all blocked-session sample rows in the window (denominator: blocked-session sample rows, so a long wait contributes one row per tick and dominates); each duration is as of its sample instant.
  lock_types: [point-sample] [json] Top 10 lock types among blocked-session sample rows in the window, each with the number of sample rows it appeared in; counts weight by time spent blocked, never by number of blocking events.
  degraded_queries_count: [derived] [count] Number of queries whose mean_exec_time averaged over statement snapshots in the incident window exceeded 1.5 times their average over the baseline window; capped at 10 by an internal limit.
  degraded_queries: [derived] [json] Up to 10 worst-degraded queries with baseline_ms, during_ms, and slowdown_pct (percent increase of the during-window mean over the baseline-window mean; denominator is the baseline mean).
  connections_before: [gauge] [count] Mean of the connections_total gauge across snapshots in the baseline window, rounded to an integer; each reading is exact at its tick, spikes between ticks are invisible.
  connections_during_avg: [gauge] [count] Mean of the connections_total gauge across snapshots in the incident window, rounded to an integer.
  connections_during_max: [gauge] [count] Maximum connections_total across snapshots in the incident window; peaks between snapshot ticks are invisible.
  connection_increase_pct: [derived] [percent] Percent change of connections_during_avg relative to connections_before (denominator: the baseline average); 0 when the baseline average is 0.
  affected_applications: [point-sample] [json] Blocked-session counts (distinct pids observed blocked in samples, biased against short waits) with max observed wait, grouped by application; the v2 lock_samples ring does not record application names, so every row currently reports app_name unknown.
  top_wait_events: [point-sample] [json] Wait events decoded from the wait_samples ring during the incident window, ordered by summed per-tick waiter counts, with pct_increase versus the same sum over the baseline window (denominator: the baseline sum; NULL when the event was absent from the baseline). Summed waiter counts estimate time-weighted wait volume, never event frequency.
  tps_before: [counter-delta] [count/s] [interval-mean] Committed-transaction rate over the baseline window: the xact_commit counter differenced between consecutive snapshots, divided by each gap, then averaged. A mean rate; within-interval bursts are invisible, and a counter reset inside the window corrupts the affected delta.
  tps_during: [counter-delta] [count/s] [interval-mean] The same estimator over the incident window: mean per-gap rate of the xact_commit counter across snapshots inside the window.
  tps_change_pct: [derived] [percent] Percent change of tps_during relative to tps_before (denominator: tps_before); 0 when the baseline TPS is 0.
  severity: [derived] [text] Overall incident severity (low, medium, high, critical): the worst of five fixed-threshold scores over blocked sessions, block duration, connection increase, TPS drop, and degraded-query count.
  impact_summary: [derived] [text] Human-readable impact statements generated from the same thresholds (blocked sessions, TPS drop, degraded queries, connection increase).
  recommendations: [derived] [text] Heuristic remediation suggestions triggered by the same thresholds.';


-- Blast Radius Report
-- Human-readable formatted report for incident postmortems
-- Returns ASCII-art styled report suitable for sharing and documentation
CREATE OR REPLACE FUNCTION pgfr_analyze.blast_radius_report(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TEXT
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_data RECORD;
    v_result TEXT := '';
    v_bar TEXT;
    v_max_bar_width INTEGER := 20;
    v_app RECORD;
    v_query RECORD;
    v_wait RECORD;
    v_lock RECORD;
    v_severity_bar TEXT;
BEGIN
    -- Get blast radius data
    SELECT * INTO v_data FROM pgfr_analyze.blast_radius(p_start_time, p_end_time);

    -- Header
    v_result := v_result || E'══════════════════════════════════════════════════════════════════════\n';
    v_result := v_result || E'                    BLAST RADIUS ANALYSIS REPORT\n';
    v_result := v_result || E'══════════════════════════════════════════════════════════════════════\n';

    -- Time window and severity
    v_result := v_result || format('Time Window: %s → %s (%s)',
        to_char(p_start_time, 'YYYY-MM-DD HH24:MI:SS'),
        to_char(p_end_time, 'HH24:MI:SS'),
        CASE
            WHEN v_data.duration_seconds >= 3600 THEN format('%s hours', round(v_data.duration_seconds / 3600, 1))
            WHEN v_data.duration_seconds >= 60 THEN format('%s minutes', round(v_data.duration_seconds / 60, 0))
            ELSE format('%s seconds', v_data.duration_seconds::integer)
        END
    ) || E'\n';

    -- Severity indicator with visual bar
    v_severity_bar := CASE v_data.severity
        WHEN 'critical' THEN '██████████'
        WHEN 'high' THEN '███████░░░'
        WHEN 'medium' THEN '█████░░░░░'
        ELSE '██░░░░░░░░'
    END;
    v_result := v_result || format('Severity: %s %s', v_severity_bar, upper(v_data.severity)) || E'\n\n';

    -- =========================================================================
    -- Lock Impact Section
    -- =========================================================================
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';
    v_result := v_result || E'LOCK IMPACT\n';
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';

    IF v_data.blocked_sessions_total > 0 THEN
        v_result := v_result || format('  Total blocked sessions:     %s', v_data.blocked_sessions_total) || E'\n';
        v_result := v_result || format('  Max concurrent blocked:     %s', v_data.blocked_sessions_max_concurrent) || E'\n';
        v_result := v_result || format('  Longest block duration:     %s',
            CASE
                WHEN v_data.max_block_duration >= interval '1 hour'
                THEN format('%sh %sm', EXTRACT(HOUR FROM v_data.max_block_duration)::integer,
                                       EXTRACT(MINUTE FROM v_data.max_block_duration)::integer)
                WHEN v_data.max_block_duration >= interval '1 minute'
                THEN format('%sm %ss', EXTRACT(MINUTE FROM v_data.max_block_duration)::integer,
                                       EXTRACT(SECOND FROM v_data.max_block_duration)::integer)
                ELSE format('%ss', round(EXTRACT(EPOCH FROM v_data.max_block_duration), 1))
            END
        ) || E'\n';
        v_result := v_result || format('  Average block duration:     %s',
            CASE
                WHEN v_data.avg_block_duration >= interval '1 minute'
                THEN format('%sm %ss', EXTRACT(MINUTE FROM v_data.avg_block_duration)::integer,
                                       EXTRACT(SECOND FROM v_data.avg_block_duration)::integer)
                ELSE format('%ss', round(EXTRACT(EPOCH FROM v_data.avg_block_duration), 1))
            END
        ) || E'\n\n';

        -- Lock types with bar chart
        IF jsonb_array_length(v_data.lock_types) > 0 THEN
            v_result := v_result || E'  Lock types:\n';
            FOR v_lock IN SELECT * FROM jsonb_to_recordset(v_data.lock_types) AS x(type text, count integer) LOOP
                v_bar := repeat('█', LEAST(v_lock.count, v_max_bar_width));
                v_result := v_result || format('    %-12s %s %s', v_lock.type, rpad(v_bar, v_max_bar_width), v_lock.count) || E'\n';
            END LOOP;
        END IF;
    ELSE
        v_result := v_result || E'  No lock contention detected.\n';
    END IF;
    v_result := v_result || E'\n';

    -- =========================================================================
    -- Affected Applications Section
    -- =========================================================================
    IF jsonb_array_length(v_data.affected_applications) > 0 THEN
        v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';
        v_result := v_result || E'AFFECTED APPLICATIONS\n';
        v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';

        FOR v_app IN SELECT * FROM jsonb_to_recordset(v_data.affected_applications)
                     AS x(app_name text, blocked_count integer, max_wait interval) LOOP
            v_bar := repeat('█', LEAST(v_app.blocked_count, v_max_bar_width));
            v_result := v_result || format('  %-16s %s %s blocked',
                left(v_app.app_name, 16), rpad(v_bar, v_max_bar_width), v_app.blocked_count) || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- =========================================================================
    -- Query Degradation Section
    -- =========================================================================
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';
    v_result := v_result || format('QUERY DEGRADATION (%s queries slowed >50%%)', v_data.degraded_queries_count) || E'\n';
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';

    IF v_data.degraded_queries_count > 0 THEN
        FOR v_query IN SELECT * FROM jsonb_to_recordset(v_data.degraded_queries)
                       AS x(queryid bigint, query_preview text, baseline_ms numeric, during_ms numeric, slowdown_pct numeric)
                       LIMIT 5 LOOP
            v_result := v_result || format('  %s', left(v_query.query_preview, 50)) || E'\n';
            v_result := v_result || format('    %sms → %sms  (+%s%%)',
                v_query.baseline_ms, v_query.during_ms, v_query.slowdown_pct::integer) || E'\n';
        END LOOP;
        IF v_data.degraded_queries_count > 5 THEN
            v_result := v_result || format('  ... and %s more', v_data.degraded_queries_count - 5) || E'\n';
        END IF;
    ELSE
        v_result := v_result || E'  No significant query degradation detected.\n';
    END IF;
    v_result := v_result || E'\n';

    -- =========================================================================
    -- Resource Impact Section
    -- =========================================================================
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';
    v_result := v_result || E'RESOURCE IMPACT\n';
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';

    v_result := v_result || format('  Connections:  %s → %s avg (%s max)  %s',
        v_data.connections_before,
        v_data.connections_during_avg,
        v_data.connections_during_max,
        CASE
            WHEN v_data.connection_increase_pct > 0 THEN format('+%s%%', v_data.connection_increase_pct::integer)
            WHEN v_data.connection_increase_pct < 0 THEN format('%s%%', v_data.connection_increase_pct::integer)
            ELSE 'unchanged'
        END
    ) || E'\n';

    v_result := v_result || format('  Throughput:   %s TPS → %s TPS    %s',
        round(v_data.tps_before, 0)::integer,
        round(v_data.tps_during, 0)::integer,
        CASE
            WHEN v_data.tps_change_pct > 0 THEN format('+%s%%', v_data.tps_change_pct::integer)
            WHEN v_data.tps_change_pct < 0 THEN format('%s%%', v_data.tps_change_pct::integer)
            ELSE 'unchanged'
        END
    ) || E'\n\n';

    -- =========================================================================
    -- Wait Events Section
    -- =========================================================================
    IF jsonb_array_length(v_data.top_wait_events) > 0 THEN
        v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';
        v_result := v_result || E'TOP WAIT EVENTS\n';
        v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';

        FOR v_wait IN SELECT * FROM jsonb_to_recordset(v_data.top_wait_events)
                      AS x(wait_type text, wait_event text, total_count integer, pct_increase numeric)
                      LIMIT 5 LOOP
            v_result := v_result || format('  %s:%s  count=%s',
                v_wait.wait_type, v_wait.wait_event, v_wait.total_count);
            IF v_wait.pct_increase IS NOT NULL THEN
                v_result := v_result || format('  (%s%s%%)',
                    CASE WHEN v_wait.pct_increase >= 0 THEN '+' ELSE '' END,
                    v_wait.pct_increase::integer);
            END IF;
            v_result := v_result || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- =========================================================================
    -- Recommendations Section
    -- =========================================================================
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';
    v_result := v_result || E'RECOMMENDATIONS\n';
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';

    FOR i IN 1..array_length(v_data.recommendations, 1) LOOP
        v_result := v_result || format('  • %s', v_data.recommendations[i]) || E'\n';
    END LOOP;
    v_result := v_result || E'\n';

    -- Footer
    v_result := v_result || E'══════════════════════════════════════════════════════════════════════\n';

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.blast_radius_report IS
'Human-readable blast radius analysis report with ASCII-art formatting. Suitable for incident postmortems, Slack/email sharing, and documentation. Includes visual severity indicators, bar charts for lock types and affected apps, and actionable recommendations. Use: SELECT pgfr_analyze.blast_radius_report(''2024-01-15 10:23:00'', ''2024-01-15 10:35:00'');';

-- =============================================================================
-- V2 PARTITIONED TABLE READER FUNCTIONS (Issue #11)
-- Queries v2 tables (statement_snapshots_v2, table_snapshots_v2,
-- index_snapshots_v2) using int4 sample_ts ranges for partition pruning.
-- These are NEW functions — existing functions are untouched (backwards compat).
-- =============================================================================

-- Helper: convert timestamptz bounds to int4 sample_ts offsets
-- Used by all v2 reader functions to derive partition-prunable range predicates.
