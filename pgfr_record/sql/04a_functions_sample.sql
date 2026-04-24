CREATE OR REPLACE FUNCTION pgfr_record.sample()
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql AS $$
DECLARE
    v_captured_at TIMESTAMPTZ := now();
    v_epoch BIGINT := extract(epoch from v_captured_at)::bigint;
    v_slot_id INTEGER;
    v_sample_interval_seconds INTEGER;
    v_enable_locks BOOLEAN;
    v_snapshot_based BOOLEAN;
    v_blocked_count INTEGER;
    v_skip_locks_threshold INTEGER;
    v_stat_id INTEGER;
    v_should_skip BOOLEAN;
BEGIN
    v_sample_interval_seconds := COALESCE(
        pgfr_record._get_config('sample_interval_seconds', '60')::integer,
        60
    );
    IF v_sample_interval_seconds < 60 THEN
        v_sample_interval_seconds := 60;
    ELSIF v_sample_interval_seconds > 3600 THEN
        v_sample_interval_seconds := 3600;
    END IF;
    v_slot_id := (v_epoch / v_sample_interval_seconds) % pgfr_record._get_ring_buffer_slots();
    v_should_skip := pgfr_record._check_circuit_breaker('sample');
    IF v_should_skip THEN
        PERFORM pgfr_record._record_collection_skip('sample', 'Circuit breaker tripped - last run exceeded threshold');
        RAISE NOTICE 'pgfr_record: Skipping sample collection due to circuit breaker';
        RETURN v_captured_at;
    END IF;
    v_stat_id := pgfr_record._record_collection_start('sample', 3);
    DECLARE
        v_lock_strategy TEXT;
        v_lock_timeout_ms INTEGER;
    BEGIN
        v_lock_strategy := COALESCE(
            pgfr_record._get_config('lock_timeout_strategy', 'fail_fast'),
            'fail_fast'
        );
        v_lock_timeout_ms := CASE v_lock_strategy
            WHEN 'skip_if_locked' THEN 0
            WHEN 'patient' THEN 500
            ELSE 100
        END;
        PERFORM set_config('lock_timeout', v_lock_timeout_ms::text, true);
    END;
    PERFORM set_config('work_mem',
        COALESCE(pgfr_record._get_config('work_mem_kb', '2048'), '2048') || 'kB',
        true);
    DECLARE
        v_load_shedding_enabled BOOLEAN;
        v_load_threshold_pct INTEGER;
        v_max_connections INTEGER;
        v_active_pct NUMERIC;
        v_active_count INTEGER;
        v_stmt_utilization NUMERIC;
        v_stmt_status TEXT;
    BEGIN
        v_load_shedding_enabled := COALESCE(
            pgfr_record._get_config('load_shedding_enabled', 'true')::boolean,
            true
        );
        IF v_load_shedding_enabled THEN
            v_load_threshold_pct := COALESCE(
                pgfr_record._get_config('load_shedding_active_pct', '70')::integer,
                70
            );
            SELECT setting::integer INTO v_max_connections
            FROM pg_settings WHERE name = 'max_connections';
            SELECT count(*) INTO v_active_count
            FROM pg_stat_activity
            WHERE state = 'active' AND backend_type = 'client backend';
            v_active_pct := (v_active_count::numeric / NULLIF(v_max_connections, 0)) * 100;
            IF v_active_pct >= v_load_threshold_pct THEN
                PERFORM pgfr_record._record_collection_skip('sample',
                    format('Load shedding: high load (%s active / %s max = %s%% >= %s%% threshold)',
                           v_active_count, v_max_connections, round(v_active_pct, 1), v_load_threshold_pct));
                PERFORM set_config('statement_timeout', '0', true);
                RETURN v_captured_at;
            END IF;
        END IF;
        IF pgfr_record._has_pg_stat_statements() THEN
            SELECT utilization_pct, status
            INTO v_stmt_utilization, v_stmt_status
            FROM pgfr_record._check_statements_health();
            IF v_stmt_status IN ('WARNING', 'HIGH_CHURN') THEN
                PERFORM pgfr_record._record_collection_skip('sample',
                    format('pg_stat_statements overhead: %s utilization (%s%%), skipping to reduce hash table pressure',
                           v_stmt_status, round(v_stmt_utilization, 1)));
                PERFORM set_config('statement_timeout', '0', true);
                RETURN v_captured_at;
            END IF;
        END IF;
    END;
    v_enable_locks := COALESCE(
        pgfr_record._get_config('enable_locks', 'true')::boolean,
        TRUE
    );
    v_snapshot_based := COALESCE(
        pgfr_record._get_config('snapshot_based_collection', 'true')::boolean,
        true
    );
    INSERT INTO pgfr_record.samples_ring (slot_id, captured_at, epoch_seconds)
    VALUES (v_slot_id, v_captured_at, v_epoch)
    ON CONFLICT (slot_id) DO UPDATE SET
        captured_at = EXCLUDED.captured_at,
        epoch_seconds = EXCLUDED.epoch_seconds;
    UPDATE pgfr_record.wait_samples_ring SET
        backend_type = NULL, wait_event_type = NULL, wait_event = NULL, state = NULL, count = NULL
    WHERE slot_id = v_slot_id;
    UPDATE pgfr_record.activity_samples_ring SET
        pid = NULL, usename = NULL, application_name = NULL, backend_type = NULL,
        state = NULL, wait_event_type = NULL, wait_event = NULL,
        backend_start = NULL, xact_start = NULL,
        query_start = NULL, state_change = NULL, query_preview = NULL
    WHERE slot_id = v_slot_id;
    UPDATE pgfr_record.lock_samples_ring SET
        blocked_pid = NULL, blocked_user = NULL, blocked_app = NULL,
        blocked_query_preview = NULL, blocked_duration = NULL, blocking_pid = NULL,
        blocking_user = NULL, blocking_app = NULL, blocking_query_preview = NULL,
        lock_type = NULL, locked_relation_oid = NULL
    WHERE slot_id = v_slot_id;
    IF v_snapshot_based THEN
        CREATE TEMP TABLE IF NOT EXISTS _fr_psa_snapshot (
            LIKE pg_stat_activity
        ) ON COMMIT DROP;
        TRUNCATE _fr_psa_snapshot;
        INSERT INTO _fr_psa_snapshot
        SELECT * FROM pg_stat_activity WHERE pid != pg_backend_pid();
    END IF;
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        IF v_snapshot_based THEN
            INSERT INTO pgfr_record.wait_samples_ring (slot_id, row_num, backend_type, wait_event_type, wait_event, state, count)
            SELECT
                v_slot_id,
                (ROW_NUMBER() OVER () - 1)::integer AS row_num,
                COALESCE(backend_type, 'unknown'),
                COALESCE(wait_event_type, 'Running'),
                COALESCE(wait_event, 'CPU'),
                COALESCE(state, 'unknown'),
                count(*)::integer
            FROM _fr_psa_snapshot
            GROUP BY backend_type, wait_event_type, wait_event, state
            LIMIT 100
            ON CONFLICT (slot_id, row_num) DO UPDATE SET
                backend_type = EXCLUDED.backend_type,
                wait_event_type = EXCLUDED.wait_event_type,
                wait_event = EXCLUDED.wait_event,
                state = EXCLUDED.state,
                count = EXCLUDED.count;
        ELSE
            INSERT INTO pgfr_record.wait_samples_ring (slot_id, row_num, backend_type, wait_event_type, wait_event, state, count)
            SELECT
                v_slot_id,
                (ROW_NUMBER() OVER () - 1)::integer AS row_num,
                COALESCE(backend_type, 'unknown'),
                COALESCE(wait_event_type, 'Running'),
                COALESCE(wait_event, 'CPU'),
                COALESCE(state, 'unknown'),
                count(*)::integer
            FROM pg_stat_activity
            WHERE pid != pg_backend_pid()
            GROUP BY backend_type, wait_event_type, wait_event, state
            LIMIT 100
            ON CONFLICT (slot_id, row_num) DO UPDATE SET
                backend_type = EXCLUDED.backend_type,
                wait_event_type = EXCLUDED.wait_event_type,
                wait_event = EXCLUDED.wait_event,
                state = EXCLUDED.state,
                count = EXCLUDED.count;
        END IF;
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Wait events collection failed: %', SQLERRM;
    END;
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        IF v_snapshot_based THEN
            INSERT INTO pgfr_record.activity_samples_ring (
                slot_id, row_num, pid, usename, application_name, client_addr, backend_type,
                state, wait_event_type, wait_event, backend_start, xact_start,
                query_start, state_change, query_preview
            )
            SELECT
                v_slot_id,
                (ROW_NUMBER() OVER (ORDER BY query_start ASC NULLS LAST) - 1)::integer AS row_num,
                pid,
                usename,
                application_name,
                client_addr,
                backend_type,
                state,
                wait_event_type,
                wait_event,
                backend_start,
                xact_start,
                query_start,
                state_change,
                left(query, 200)
            FROM _fr_psa_snapshot
            WHERE state != 'idle'
            LIMIT 25
            ON CONFLICT (slot_id, row_num) DO UPDATE SET
                pid = EXCLUDED.pid,
                usename = EXCLUDED.usename,
                application_name = EXCLUDED.application_name,
                client_addr = EXCLUDED.client_addr,
                backend_type = EXCLUDED.backend_type,
                state = EXCLUDED.state,
                wait_event_type = EXCLUDED.wait_event_type,
                wait_event = EXCLUDED.wait_event,
                backend_start = EXCLUDED.backend_start,
                xact_start = EXCLUDED.xact_start,
                query_start = EXCLUDED.query_start,
                state_change = EXCLUDED.state_change,
                query_preview = EXCLUDED.query_preview;
        ELSE
            INSERT INTO pgfr_record.activity_samples_ring (
                slot_id, row_num, pid, usename, application_name, client_addr, backend_type,
                state, wait_event_type, wait_event, backend_start, xact_start,
                query_start, state_change, query_preview
            )
            SELECT
                v_slot_id,
                (ROW_NUMBER() OVER (ORDER BY query_start ASC NULLS LAST) - 1)::integer AS row_num,
                pid,
                usename,
                application_name,
                client_addr,
                backend_type,
                state,
                wait_event_type,
                wait_event,
                backend_start,
                xact_start,
                query_start,
                state_change,
                left(query, 200)
            FROM pg_stat_activity
            WHERE state != 'idle' AND pid != pg_backend_pid()
            LIMIT 25
            ON CONFLICT (slot_id, row_num) DO UPDATE SET
                pid = EXCLUDED.pid,
                usename = EXCLUDED.usename,
                application_name = EXCLUDED.application_name,
                client_addr = EXCLUDED.client_addr,
                backend_type = EXCLUDED.backend_type,
                state = EXCLUDED.state,
                wait_event_type = EXCLUDED.wait_event_type,
                wait_event = EXCLUDED.wait_event,
                backend_start = EXCLUDED.backend_start,
                xact_start = EXCLUDED.xact_start,
                query_start = EXCLUDED.query_start,
                state_change = EXCLUDED.state_change,
                query_preview = EXCLUDED.query_preview;
        END IF;
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Activity samples collection failed: %', SQLERRM;
    END;
    IF v_enable_locks THEN
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        DECLARE
            v_blocked_count INTEGER;
            v_skip_locks_threshold INTEGER;
        BEGIN
            v_skip_locks_threshold := COALESCE(
                pgfr_record._get_config('skip_locks_threshold', '50')::integer,
                50
            );
            IF v_snapshot_based THEN
                CREATE TEMP TABLE _fr_blocked_sessions ON COMMIT DROP AS
                SELECT
                    pid,
                    usename,
                    application_name,
                    query,
                    query_start,
                    wait_event_type,
                    wait_event,
                    pg_blocking_pids(pid) AS blocking_pids
                FROM _fr_psa_snapshot
                WHERE cardinality(pg_blocking_pids(pid)) > 0;
            ELSE
                CREATE TEMP TABLE _fr_blocked_sessions ON COMMIT DROP AS
                SELECT
                    pid,
                    usename,
                    application_name,
                    query,
                    query_start,
                    wait_event_type,
                    wait_event,
                    pg_blocking_pids(pid) AS blocking_pids
                FROM pg_stat_activity
                WHERE pid != pg_backend_pid()
                  AND cardinality(pg_blocking_pids(pid)) > 0;
            END IF;
            SELECT count(*) INTO v_blocked_count FROM _fr_blocked_sessions;
            IF v_blocked_count > v_skip_locks_threshold THEN
                RAISE NOTICE 'pgfr_record: Skipping lock collection - % blocked sessions exceeds threshold %',
                    v_blocked_count, v_skip_locks_threshold;
            ELSE
                INSERT INTO pgfr_record.lock_samples_ring (
                    slot_id, row_num, blocked_pid, blocked_user, blocked_app,
                    blocked_query_preview, blocked_duration, blocking_pid, blocking_user,
                    blocking_app, blocking_query_preview, lock_type, locked_relation_oid
                )
                SELECT
                    v_slot_id,
                    (ROW_NUMBER() OVER (ORDER BY bs.pid, blocking_pid) - 1)::integer AS row_num,
                    bs.pid,
                    bs.usename,
                    bs.application_name,
                    left(bs.query, 200),
                    v_captured_at - bs.query_start,
                    blocking_pid,
                    blocking.usename,
                    blocking.application_name,
                    left(blocking.query, 200),
                    CASE
                        WHEN bs.wait_event_type = 'Lock' THEN bs.wait_event
                        ELSE 'unknown'
                    END,
                    CASE
                        WHEN bs.wait_event IN ('relation', 'extend', 'page', 'tuple') THEN
                            (SELECT l.relation
                             FROM pg_locks l
                             WHERE l.pid = bs.pid AND NOT l.granted
                             LIMIT 1)
                        ELSE NULL
                    END
                FROM (
                    SELECT DISTINCT ON (bs.pid, blocking_pid)
                        bs.*,
                        blocking_pid
                    FROM _fr_blocked_sessions bs
                    CROSS JOIN LATERAL unnest(bs.blocking_pids) AS blocking_pid
                    ORDER BY bs.pid, blocking_pid
                    LIMIT 100
                ) bs
                JOIN pg_stat_activity blocking ON blocking.pid = bs.blocking_pid
                ON CONFLICT (slot_id, row_num) DO UPDATE SET
                    blocked_pid = EXCLUDED.blocked_pid,
                    blocked_user = EXCLUDED.blocked_user,
                    blocked_app = EXCLUDED.blocked_app,
                    blocked_query_preview = EXCLUDED.blocked_query_preview,
                    blocked_duration = EXCLUDED.blocked_duration,
                    blocking_pid = EXCLUDED.blocking_pid,
                    blocking_user = EXCLUDED.blocking_user,
                    blocking_app = EXCLUDED.blocking_app,
                    blocking_query_preview = EXCLUDED.blocking_query_preview,
                    lock_type = EXCLUDED.lock_type,
                    locked_relation_oid = EXCLUDED.locked_relation_oid;
            END IF;
        END;
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Lock sampling collection failed: %', SQLERRM;
    END;
    END IF;
    PERFORM pgfr_record._record_collection_end(v_stat_id, true, NULL);
    PERFORM set_config('statement_timeout', '0', true);
    RETURN v_captured_at;
EXCEPTION
    WHEN OTHERS THEN
        PERFORM pgfr_record._record_collection_end(v_stat_id, false, SQLERRM);
        PERFORM set_config('statement_timeout', '0', true);
        RAISE WARNING 'pgfr_record: Sample collection failed: %', SQLERRM;
        RETURN v_captured_at;
END;
$$;
COMMENT ON FUNCTION pgfr_record.sample() IS 'Sampled activity: Collect samples into ring buffer (configurable interval, default 60s, 3 sections: waits, activity, locks)';


-- Aggregates: Aggregate wait events, lock conflicts, and query activity from ring buffers into durable aggregate tables
CREATE OR REPLACE FUNCTION pgfr_record.flush_ring_to_aggregates()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_start_time TIMESTAMPTZ;
    v_end_time TIMESTAMPTZ;
    v_total_samples INTEGER;
    v_last_flush TIMESTAMPTZ;
BEGIN
    SELECT COALESCE(max(end_time), '1970-01-01')
    INTO v_last_flush
    FROM pgfr_record.wait_event_aggregates;
    SELECT min(captured_at), max(captured_at), count(*)
    INTO v_start_time, v_end_time, v_total_samples
    FROM pgfr_record.samples_ring
    WHERE captured_at > v_last_flush;
    IF v_start_time IS NULL OR v_total_samples = 0 THEN
        RETURN;
    END IF;
    INSERT INTO pgfr_record.wait_event_aggregates (
        start_time, end_time, backend_type, wait_event_type, wait_event, state,
        sample_count, total_waiters, avg_waiters, max_waiters, pct_of_samples
    )
    SELECT
        v_start_time,
        v_end_time,
        w.backend_type,
        w.wait_event_type,
        w.wait_event,
        w.state,
        count(DISTINCT w.slot_id) AS sample_count,
        sum(w.count) AS total_waiters,
        round(avg(w.count), 2) AS avg_waiters,
        max(w.count) AS max_waiters,
        round(100.0 * count(DISTINCT w.slot_id) / NULLIF(v_total_samples, 0), 1) AS pct_of_samples
    FROM pgfr_record.wait_samples_ring w
    JOIN pgfr_record.samples_ring s ON s.slot_id = w.slot_id
    WHERE s.captured_at BETWEEN v_start_time AND v_end_time
      AND w.backend_type IS NOT NULL
    GROUP BY w.backend_type, w.wait_event_type, w.wait_event, w.state;
    INSERT INTO pgfr_record.lock_aggregates (
        start_time, end_time, blocked_user, blocking_user, lock_type,
        locked_relation_oid, occurrence_count, max_duration, avg_duration, sample_query
    )
    SELECT
        v_start_time,
        v_end_time,
        l.blocked_user,
        l.blocking_user,
        l.lock_type,
        l.locked_relation_oid,
        count(*) AS occurrence_count,
        max(l.blocked_duration) AS max_duration,
        avg(l.blocked_duration) AS avg_duration,
        min(l.blocked_query_preview) AS sample_query
    FROM pgfr_record.lock_samples_ring l
    JOIN pgfr_record.samples_ring s ON s.slot_id = l.slot_id
    WHERE s.captured_at BETWEEN v_start_time AND v_end_time
      AND l.blocked_pid IS NOT NULL
    GROUP BY l.blocked_user, l.blocking_user, l.lock_type, l.locked_relation_oid;
    INSERT INTO pgfr_record.activity_aggregates (
        start_time, end_time, query_preview, occurrence_count, max_duration, avg_duration
    )
    SELECT
        v_start_time,
        v_end_time,
        a.query_preview,
        count(*) AS occurrence_count,
        max(s.captured_at - a.query_start) AS max_duration,
        avg(s.captured_at - a.query_start) AS avg_duration
    FROM pgfr_record.activity_samples_ring a
    JOIN pgfr_record.samples_ring s ON s.slot_id = a.slot_id
    WHERE s.captured_at BETWEEN v_start_time AND v_end_time
      AND a.pid IS NOT NULL
      AND a.query_start IS NOT NULL
    GROUP BY a.query_preview;
    RAISE NOTICE 'pgfr_record: Flushed ring buffer (% to %, % samples)',
        v_start_time, v_end_time, v_total_samples;
END;
$$;
COMMENT ON FUNCTION pgfr_record.flush_ring_to_aggregates() IS 'Aggregates: Flush ring buffer to durable aggregates every 5 minutes';


-- Archives activity, lock, and wait samples from ring buffers to persistent storage for forensic analysis
-- Executes periodically (default every 15 minutes) based on configuration settings
CREATE OR REPLACE FUNCTION pgfr_record.archive_ring_samples()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
    v_archive_activity BOOLEAN;
    v_archive_locks BOOLEAN;
    v_archive_waits BOOLEAN;
    v_frequency_minutes INTEGER;
    v_last_archive TIMESTAMPTZ;
    v_next_archive_due TIMESTAMPTZ;
    v_samples_to_archive INTEGER;
    v_activity_rows INTEGER := 0;
    v_lock_rows INTEGER := 0;
    v_wait_rows INTEGER := 0;
BEGIN
    v_enabled := COALESCE(
        (SELECT value::boolean FROM pgfr_record.config WHERE key = 'archive_samples_enabled'),
        true
    );
    IF NOT v_enabled THEN
        RETURN;
    END IF;
    v_archive_activity := COALESCE(
        (SELECT value::boolean FROM pgfr_record.config WHERE key = 'archive_activity_samples'),
        true
    );
    v_archive_locks := COALESCE(
        (SELECT value::boolean FROM pgfr_record.config WHERE key = 'archive_lock_samples'),
        true
    );
    v_archive_waits := COALESCE(
        (SELECT value::boolean FROM pgfr_record.config WHERE key = 'archive_wait_samples'),
        true
    );
    v_frequency_minutes := COALESCE(
        (SELECT value::integer FROM pgfr_record.config WHERE key = 'archive_sample_frequency_minutes'),
        15
    );
    SELECT GREATEST(
        COALESCE(MAX(captured_at), '1970-01-01'::timestamptz),
        COALESCE((SELECT MAX(captured_at) FROM pgfr_record.lock_samples_archive), '1970-01-01'::timestamptz),
        COALESCE((SELECT MAX(captured_at) FROM pgfr_record.wait_samples_archive), '1970-01-01'::timestamptz)
    )
    INTO v_last_archive
    FROM pgfr_record.activity_samples_archive;
    v_next_archive_due := v_last_archive + (v_frequency_minutes || ' minutes')::interval;
    IF now() < v_next_archive_due THEN
        RETURN;
    END IF;
    SELECT count(DISTINCT slot_id)
    INTO v_samples_to_archive
    FROM pgfr_record.samples_ring
    WHERE captured_at > v_last_archive;
    IF v_samples_to_archive = 0 THEN
        RETURN;
    END IF;
    IF v_archive_activity THEN
        INSERT INTO pgfr_record.activity_samples_archive (
            sample_id, captured_at, pid, usename, application_name, client_addr, backend_type,
            state, wait_event_type, wait_event, backend_start, xact_start,
            query_start, state_change, query_preview
        )
        SELECT
            s.epoch_seconds AS sample_id,
            s.captured_at,
            a.pid,
            a.usename,
            a.application_name,
            a.client_addr,
            a.backend_type,
            a.state,
            a.wait_event_type,
            a.wait_event,
            a.backend_start,
            a.xact_start,
            a.query_start,
            a.state_change,
            a.query_preview
        FROM pgfr_record.activity_samples_ring a
        JOIN pgfr_record.samples_ring s ON s.slot_id = a.slot_id
        WHERE s.captured_at > v_last_archive
          AND a.pid IS NOT NULL;
        GET DIAGNOSTICS v_activity_rows = ROW_COUNT;
    END IF;
    IF v_archive_locks THEN
        INSERT INTO pgfr_record.lock_samples_archive (
            sample_id, captured_at, blocked_pid, blocked_user, blocked_app,
            blocked_query_preview, blocked_duration, blocking_pid, blocking_user,
            blocking_app, blocking_query_preview, lock_type, locked_relation_oid
        )
        SELECT
            s.epoch_seconds AS sample_id,
            s.captured_at,
            l.blocked_pid,
            l.blocked_user,
            l.blocked_app,
            l.blocked_query_preview,
            l.blocked_duration,
            l.blocking_pid,
            l.blocking_user,
            l.blocking_app,
            l.blocking_query_preview,
            l.lock_type,
            l.locked_relation_oid
        FROM pgfr_record.lock_samples_ring l
        JOIN pgfr_record.samples_ring s ON s.slot_id = l.slot_id
        WHERE s.captured_at > v_last_archive
          AND l.blocked_pid IS NOT NULL;
        GET DIAGNOSTICS v_lock_rows = ROW_COUNT;
    END IF;
    IF v_archive_waits THEN
        INSERT INTO pgfr_record.wait_samples_archive (
            sample_id, captured_at, backend_type, wait_event_type, wait_event, state, count
        )
        SELECT
            s.epoch_seconds AS sample_id,
            s.captured_at,
            w.backend_type,
            w.wait_event_type,
            w.wait_event,
            w.state,
            w.count
        FROM pgfr_record.wait_samples_ring w
        JOIN pgfr_record.samples_ring s ON s.slot_id = w.slot_id
        WHERE s.captured_at > v_last_archive
          AND w.backend_type IS NOT NULL;
        GET DIAGNOSTICS v_wait_rows = ROW_COUNT;
    END IF;
    RAISE NOTICE 'pgfr_record: Archived raw samples (% samples, % activity rows, % lock rows, % wait rows)',
        v_samples_to_archive, v_activity_rows, v_lock_rows, v_wait_rows;
END;
$$;
COMMENT ON FUNCTION pgfr_record.archive_ring_samples() IS 'Raw archives: Archive raw samples for high-resolution forensic analysis (default: every 15 minutes)';


-- Removes aged aggregate and archived sample data based on configured retention periods
-- Deletes expired records from wait_event_aggregates, lock_aggregates, activity_aggregates, and all *_samples_archive tables
CREATE OR REPLACE FUNCTION pgfr_record.cleanup_aggregates()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_aggregate_retention interval;
    v_archive_retention interval;
    v_deleted_waits INTEGER;
    v_deleted_locks INTEGER;
    v_deleted_queries INTEGER;
    v_deleted_activity_archive INTEGER;
    v_deleted_lock_archive INTEGER;
    v_deleted_wait_archive INTEGER;
BEGIN
    v_aggregate_retention := (pgfr_record._get_config('aggregate_retention_days', '7') || ' days')::interval;
    v_archive_retention   := (pgfr_record._get_config('archive_retention_days', '7') || ' days')::interval;
    DELETE FROM pgfr_record.wait_event_aggregates
    WHERE start_time < now() - v_aggregate_retention;
    GET DIAGNOSTICS v_deleted_waits = ROW_COUNT;
    DELETE FROM pgfr_record.lock_aggregates
    WHERE start_time < now() - v_aggregate_retention;
    GET DIAGNOSTICS v_deleted_locks = ROW_COUNT;
    DELETE FROM pgfr_record.activity_aggregates
    WHERE start_time < now() - v_aggregate_retention;
    GET DIAGNOSTICS v_deleted_queries = ROW_COUNT;
    DELETE FROM pgfr_record.activity_samples_archive
    WHERE captured_at < now() - v_archive_retention;
    GET DIAGNOSTICS v_deleted_activity_archive = ROW_COUNT;
    DELETE FROM pgfr_record.lock_samples_archive
    WHERE captured_at < now() - v_archive_retention;
    GET DIAGNOSTICS v_deleted_lock_archive = ROW_COUNT;
    DELETE FROM pgfr_record.wait_samples_archive
    WHERE captured_at < now() - v_archive_retention;
    GET DIAGNOSTICS v_deleted_wait_archive = ROW_COUNT;
    IF v_deleted_waits > 0 OR v_deleted_locks > 0 OR v_deleted_queries > 0 OR
       v_deleted_activity_archive > 0 OR v_deleted_lock_archive > 0 OR v_deleted_wait_archive > 0 THEN
        RAISE NOTICE 'pgfr_record: Cleaned up % wait aggregates, % lock aggregates, % query aggregates, % activity archives, % lock archives, % wait archives',
            v_deleted_waits, v_deleted_locks, v_deleted_queries, v_deleted_activity_archive, v_deleted_lock_archive, v_deleted_wait_archive;
    END IF;
END;
$$;
COMMENT ON FUNCTION pgfr_record.cleanup_aggregates() IS 'Cleanup: Remove old aggregate and archive data based on retention periods';


-- Collects table-level statistics from pg_stat_user_tables
-- Captures tables based on configurable sampling mode: top_n, all, or threshold
CREATE OR REPLACE FUNCTION pgfr_record._collect_table_stats(p_snapshot_id BIGINT)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
    v_top_n INTEGER;
    v_mode TEXT;
    v_threshold BIGINT;
BEGIN
    v_enabled := COALESCE(
        pgfr_record._get_config('table_stats_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    v_top_n := COALESCE(
        pgfr_record._get_config('table_stats_top_n', '50')::integer,
        50
    );

    v_mode := COALESCE(
        pgfr_record._get_config('table_stats_mode', 'top_n'),
        'top_n'
    );

    v_threshold := COALESCE(
        pgfr_record._get_config('table_stats_activity_threshold', '0')::bigint,
        0
    );

    -- Handle different collection modes
    IF v_mode = 'all' THEN
        -- Collect all user tables
        -- Note: schemaname/relname are deprecated; derive via relation_names or ::regclass
        INSERT INTO pgfr_record.table_snapshots (
            snapshot_id, schemaname, relname, relid,
            seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
            n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
            n_live_tup, n_dead_tup, n_mod_since_analyze,
            vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
            last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
            relfrozenxid_age, relminmxid_age, reltuples, vacuum_running,
            table_size_bytes, total_size_bytes, indexes_size_bytes
        )
        SELECT
            p_snapshot_id,
            NULL,  -- schemaname deprecated: derive via relid
            NULL,  -- relname deprecated: derive via relid
            st.relid,
            st.seq_scan,
            st.seq_tup_read,
            st.idx_scan,
            st.idx_tup_fetch,
            st.n_tup_ins,
            st.n_tup_upd,
            st.n_tup_del,
            st.n_tup_hot_upd,
            st.n_live_tup,
            st.n_dead_tup,
            st.n_mod_since_analyze,
            st.vacuum_count,
            st.autovacuum_count,
            st.analyze_count,
            st.autoanalyze_count,
            st.last_vacuum,
            st.last_autovacuum,
            st.last_analyze,
            st.last_autoanalyze,
            nullif(age(c.relfrozenxid)::integer, 2147483647) AS relfrozenxid_age,
            nullif(mxid_age(c.relminmxid)::integer, 2147483647) AS relminmxid_age,
            c.reltuples::bigint AS reltuples,
            EXISTS(SELECT 1 FROM pg_stat_progress_vacuum pv WHERE pv.relid = st.relid) AS vacuum_running,
            pg_relation_size(st.relid),
            pg_total_relation_size(st.relid),
            pg_indexes_size(st.relid)
        FROM pg_stat_user_tables st
        LEFT JOIN pg_class c ON c.oid = st.relid;

    ELSIF v_mode = 'threshold' THEN
        -- Collect tables with activity score above threshold
        -- Note: schemaname/relname are deprecated; derive via relation_names or ::regclass
        INSERT INTO pgfr_record.table_snapshots (
            snapshot_id, schemaname, relname, relid,
            seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
            n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
            n_live_tup, n_dead_tup, n_mod_since_analyze,
            vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
            last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
            relfrozenxid_age, relminmxid_age, reltuples, vacuum_running,
            table_size_bytes, total_size_bytes, indexes_size_bytes
        )
        SELECT
            p_snapshot_id,
            NULL,  -- schemaname deprecated: derive via relid
            NULL,  -- relname deprecated: derive via relid
            st.relid,
            st.seq_scan,
            st.seq_tup_read,
            st.idx_scan,
            st.idx_tup_fetch,
            st.n_tup_ins,
            st.n_tup_upd,
            st.n_tup_del,
            st.n_tup_hot_upd,
            st.n_live_tup,
            st.n_dead_tup,
            st.n_mod_since_analyze,
            st.vacuum_count,
            st.autovacuum_count,
            st.analyze_count,
            st.autoanalyze_count,
            st.last_vacuum,
            st.last_autovacuum,
            st.last_analyze,
            st.last_autoanalyze,
            nullif(age(c.relfrozenxid)::integer, 2147483647) AS relfrozenxid_age,
            nullif(mxid_age(c.relminmxid)::integer, 2147483647) AS relminmxid_age,
            c.reltuples::bigint AS reltuples,
            EXISTS(SELECT 1 FROM pg_stat_progress_vacuum pv WHERE pv.relid = st.relid) AS vacuum_running,
            pg_relation_size(st.relid),
            pg_total_relation_size(st.relid),
            pg_indexes_size(st.relid)
        FROM pg_stat_user_tables st
        LEFT JOIN pg_class c ON c.oid = st.relid
        WHERE (COALESCE(st.seq_tup_read, 0) + COALESCE(st.idx_tup_fetch, 0) +
               COALESCE(st.n_tup_ins, 0) + COALESCE(st.n_tup_upd, 0) + COALESCE(st.n_tup_del, 0)) >= v_threshold;

    ELSE
        -- Default: top_n mode (also handles invalid mode values)
        -- Note: schemaname/relname are deprecated; derive via relation_names or ::regclass
        INSERT INTO pgfr_record.table_snapshots (
            snapshot_id, schemaname, relname, relid,
            seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
            n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
            n_live_tup, n_dead_tup, n_mod_since_analyze,
            vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
            last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
            relfrozenxid_age, relminmxid_age, reltuples, vacuum_running,
            table_size_bytes, total_size_bytes, indexes_size_bytes
        )
        SELECT
            p_snapshot_id,
            NULL,  -- schemaname deprecated: derive via relid
            NULL,  -- relname deprecated: derive via relid
            st.relid,
            st.seq_scan,
            st.seq_tup_read,
            st.idx_scan,
            st.idx_tup_fetch,
            st.n_tup_ins,
            st.n_tup_upd,
            st.n_tup_del,
            st.n_tup_hot_upd,
            st.n_live_tup,
            st.n_dead_tup,
            st.n_mod_since_analyze,
            st.vacuum_count,
            st.autovacuum_count,
            st.analyze_count,
            st.autoanalyze_count,
            st.last_vacuum,
            st.last_autovacuum,
            st.last_analyze,
            st.last_autoanalyze,
            nullif(age(c.relfrozenxid)::integer, 2147483647) AS relfrozenxid_age,
            nullif(mxid_age(c.relminmxid)::integer, 2147483647) AS relminmxid_age,
            c.reltuples::bigint AS reltuples,
            EXISTS(SELECT 1 FROM pg_stat_progress_vacuum pv WHERE pv.relid = st.relid) AS vacuum_running,
            pg_relation_size(st.relid),
            pg_total_relation_size(st.relid),
            pg_indexes_size(st.relid)
        FROM pg_stat_user_tables st
        LEFT JOIN pg_class c ON c.oid = st.relid
        ORDER BY (COALESCE(st.seq_tup_read, 0) + COALESCE(st.idx_tup_fetch, 0) +
                  COALESCE(st.n_tup_ins, 0) + COALESCE(st.n_tup_upd, 0) + COALESCE(st.n_tup_del, 0)) DESC
        LIMIT v_top_n;
    END IF;

END;
$$;


-- Collects index-level statistics from pg_stat_user_indexes
-- Captures all user indexes with their usage metrics and sizes
CREATE OR REPLACE FUNCTION pgfr_record._collect_index_stats(p_snapshot_id BIGINT)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
BEGIN
    v_enabled := COALESCE(
        pgfr_record._get_config('index_stats_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Note: schemaname/relname/indexrelname are deprecated; derive via relation_names or ::regclass
    INSERT INTO pgfr_record.index_snapshots (
        snapshot_id, schemaname, relname, indexrelname, relid, indexrelid,
        idx_scan, idx_tup_read, idx_tup_fetch, index_size_bytes
    )
    SELECT
        p_snapshot_id,
        NULL,  -- schemaname deprecated: derive via relid
        NULL,  -- relname deprecated: derive via relid
        NULL,  -- indexrelname deprecated: derive via indexrelid
        i.relid,
        i.indexrelid,
        i.idx_scan,
        i.idx_tup_read,
        i.idx_tup_fetch,
        pg_relation_size(i.indexrelid) AS index_size_bytes
    FROM pg_stat_user_indexes i;
END;
$$;


-- Collects PostgreSQL configuration snapshot from pg_settings
-- Captures relevant settings for incident analysis and change tracking
CREATE OR REPLACE FUNCTION pgfr_record._collect_config_snapshot(p_snapshot_id BIGINT)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
    v_relevant_params TEXT[] := ARRAY[
        -- Memory
        'shared_buffers',
        'work_mem',
        'maintenance_work_mem',
        'effective_cache_size',
        'temp_buffers',
        -- Connections
        'max_connections',
        'superuser_reserved_connections',
        -- Query Planning
        'random_page_cost',
        'seq_page_cost',
        'effective_io_concurrency',
        'default_statistics_target',
        'enable_seqscan',
        'enable_indexscan',
        'enable_bitmapscan',
        'enable_hashjoin',
        'enable_mergejoin',
        'enable_nestloop',
        -- Parallelism
        'max_parallel_workers',
        'max_parallel_workers_per_gather',
        'max_worker_processes',
        'parallel_setup_cost',
        'parallel_tuple_cost',
        -- WAL
        'wal_level',
        'max_wal_size',
        'min_wal_size',
        'wal_buffers',
        'checkpoint_timeout',
        'checkpoint_completion_target',
        'checkpoint_warning',
        -- Autovacuum
        'autovacuum',
        'autovacuum_max_workers',
        'autovacuum_naptime',
        'autovacuum_vacuum_threshold',
        'autovacuum_vacuum_scale_factor',
        'autovacuum_analyze_threshold',
        'autovacuum_analyze_scale_factor',
        'autovacuum_vacuum_cost_delay',
        'autovacuum_vacuum_cost_limit',
        'autovacuum_freeze_max_age',
        -- Logging
        'log_min_duration_statement',
        'log_lock_waits',
        'log_temp_files',
        'log_autovacuum_min_duration',
        -- Statement Behavior
        'statement_timeout',
        'lock_timeout',
        'idle_in_transaction_session_timeout',
        -- Resource Limits
        'temp_file_limit',
        'max_prepared_transactions',
        'max_locks_per_transaction',
        -- Extensions
        'shared_preload_libraries',
        'pg_stat_statements.track',
        'pg_stat_statements.max'
    ];
BEGIN
    v_enabled := COALESCE(
        pgfr_record._get_config('config_snapshots_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Only insert parameters that have changed since the most recent snapshot
    -- This reduces storage by 99%+ in stable environments while maintaining
    -- full point-in-time query capability via DISTINCT ON (cs.name) pattern
    INSERT INTO pgfr_record.config_snapshots (
        snapshot_id, name, setting, unit, source, sourcefile
    )
    WITH latest_config AS (
        SELECT DISTINCT ON (cs.name)
            cs.name,
            cs.setting,
            cs.unit,
            cs.source,
            cs.sourcefile
        FROM pgfr_record.config_snapshots cs
        JOIN pgfr_record.snapshots s ON s.id = cs.snapshot_id
        WHERE s.id < p_snapshot_id  -- Previous snapshots only
        ORDER BY cs.name, s.id DESC
    )
    SELECT
        p_snapshot_id,
        pg.name,
        pg.setting,
        pg.unit,
        pg.source,
        pg.sourcefile
    FROM pg_settings pg
    WHERE pg.name = ANY(v_relevant_params)
    AND (
        -- No previous snapshot exists (first run)
        NOT EXISTS (SELECT 1 FROM latest_config)
        OR
        -- Parameter didn't exist in previous snapshot (new parameter tracked)
        NOT EXISTS (SELECT 1 FROM latest_config lc WHERE lc.name = pg.name)
        OR
        -- Parameter value changed
        EXISTS (
            SELECT 1 FROM latest_config lc
            WHERE lc.name = pg.name
            AND (
                lc.setting IS DISTINCT FROM pg.setting
                OR lc.source IS DISTINCT FROM pg.source
                OR lc.sourcefile IS DISTINCT FROM pg.sourcefile
            )
        )
    );
END;
$$;


-- Collects database-level and role-level configuration overrides from pg_db_role_setting
-- These overrides (ALTER DATABASE/ROLE SET) can significantly impact performance but are easily overlooked
CREATE OR REPLACE FUNCTION pgfr_record._collect_db_role_config_snapshot(p_snapshot_id BIGINT)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
BEGIN
    v_enabled := COALESCE(
        pgfr_record._get_config('db_role_config_snapshots_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Only insert database/role config overrides that have changed since the most recent snapshot
    -- This reduces storage significantly in stable environments
    INSERT INTO pgfr_record.db_role_config_snapshots (
        snapshot_id, database_name, role_name, parameter_name, parameter_value
    )
    WITH latest_db_role_config AS (
        SELECT DISTINCT ON (drc.database_name, drc.role_name, drc.parameter_name)
            drc.database_name,
            drc.role_name,
            drc.parameter_name,
            drc.parameter_value
        FROM pgfr_record.db_role_config_snapshots drc
        JOIN pgfr_record.snapshots s ON s.id = drc.snapshot_id
        WHERE s.id < p_snapshot_id  -- Previous snapshots only
        ORDER BY drc.database_name, drc.role_name, drc.parameter_name, s.id DESC
    ),
    current_config AS (
        SELECT
            p_snapshot_id AS snapshot_id,
            COALESCE(d.datname, '') AS database_name,
            COALESCE(r.rolname, '') AS role_name,
            split_part(setting, '=', 1) AS parameter_name,
            split_part(setting, '=', 2) AS parameter_value
        FROM pg_db_role_setting drs
        CROSS JOIN LATERAL unnest(drs.setconfig) AS setting
        LEFT JOIN pg_database d ON d.oid = drs.setdatabase
        LEFT JOIN pg_roles r ON r.oid = drs.setrole
        WHERE drs.setconfig IS NOT NULL
    )
    SELECT
        cc.snapshot_id,
        cc.database_name,
        cc.role_name,
        cc.parameter_name,
        cc.parameter_value
    FROM current_config cc
    WHERE (
        -- No previous snapshot exists (first run)
        NOT EXISTS (SELECT 1 FROM latest_db_role_config)
        OR
        -- Override didn't exist in previous snapshot (new override)
        NOT EXISTS (
            SELECT 1 FROM latest_db_role_config lc
            WHERE lc.database_name = cc.database_name
            AND lc.role_name = cc.role_name
            AND lc.parameter_name = cc.parameter_name
        )
        OR
        -- Override value changed
        EXISTS (
            SELECT 1 FROM latest_db_role_config lc
            WHERE lc.database_name = cc.database_name
            AND lc.role_name = cc.role_name
            AND lc.parameter_name = cc.parameter_name
            AND lc.parameter_value IS DISTINCT FROM cc.parameter_value
        )
    )
    UNION ALL
    -- Capture removed overrides as NULL value to track deletions
    SELECT
        p_snapshot_id,
        lc.database_name,
        lc.role_name,
        lc.parameter_name,
        NULL AS parameter_value
    FROM latest_db_role_config lc
    WHERE NOT EXISTS (
        SELECT 1 FROM current_config cc
        WHERE cc.database_name = lc.database_name
        AND cc.role_name = lc.role_name
        AND cc.parameter_name = lc.parameter_name
    );
END;
$$;


-- Snapshots: Collect comprehensive snapshot of PostgreSQL system metrics (WAL, checkpoints, I/O, replication, statements)
-- Returns the captured timestamp for downstream processing and analysis
