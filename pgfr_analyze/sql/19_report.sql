-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- report(): a human- and AI-legible markdown rendering of every analysis
-- function built in this milestone, for a window [p_from_t, p_to_t].
-- summary_report() composes the same functions into a queryable table;
-- this renders them as prose with markdown tables per section.
--
-- Wait Event Summary and Lock Contention (v1 sections) are not included:
-- both depended on v1's now-gone wait/lock ring buffer, and belong to the
-- activity/lock/wait forensics group deliberately deferred to a later,
-- purpose-built pass (anomaly_report()'s LOCK_CONTENTION check and
-- long_running_transactions() below cover the buildable-now part of that
-- ground). Role Configuration Changes is not included either: it would
-- need a pg_db_role_setting capture pgfr_record does not have, descoped
-- as a fast-follow candidate.

CREATE OR REPLACE FUNCTION pgfr_analyze.report(p_from_t timestamptz, p_to_t timestamptz)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_result    text := '';
    v_row       record;
    v_count     bigint;
    v_cov_line  text;
    v_min_ratio numeric;
    v_gap_count bigint;
BEGIN
    -- Header: coverage and gaps qualify everything that follows.
    SELECT string_agg(format('%s/%s %s (%s%%)', c.observed_runs, round(c.expected_runs, 1), c.cadence_tier, round(c.coverage_ratio * 100, 1)), ', ' ORDER BY c.cadence_tier),
           min(c.coverage_ratio)
    INTO v_cov_line, v_min_ratio
    FROM pgfr_analyze.coverage(p_from_t, p_to_t) c;

    SELECT count(*) INTO v_gap_count FROM pgfr_analyze.coverage_gaps(p_from_t, p_to_t) WHERE missed_ticks IS NOT NULL AND missed_ticks > 0;

    v_result := v_result || '# pg_flight_recorder Report' || E'\n\n';
    v_result := v_result || '**Generated:** ' || to_char(clock_timestamp(), 'YYYY-MM-DD HH24:MI:SS TZ') || E'\n';
    v_result := v_result || '**Range:** ' || to_char(p_from_t, 'YYYY-MM-DD HH24:MI:SS') || ' to ' || to_char(p_to_t, 'YYYY-MM-DD HH24:MI:SS') || E'\n';
    v_result := v_result || '**Coverage:** ' || coalesce(v_cov_line, 'no expected ticks in window');
    IF coalesce(v_gap_count, 0) > 0 THEN
        v_result := v_result || format('; %s tier(s) with missed ticks (see coverage_gaps())', v_gap_count);
    END IF;
    v_result := v_result || E'\n';
    IF v_min_ratio IS NOT NULL AND v_min_ratio < 0.9 THEN
        v_result := v_result || 'Coverage is below 90% for at least one tier in this window; conclusions below are qualified accordingly.' || E'\n';
    END IF;
    v_result := v_result || E'\n';

    -- Anomalies.
    v_result := v_result || '## Anomalies' || E'\n\n';
    SELECT count(*) INTO v_count FROM pgfr_analyze.anomaly_report(p_from_t, p_to_t);
    IF v_count = 0 THEN
        v_result := v_result || '**No anomalies detected.**' || E'\n\n';
    ELSE
        v_result := v_result || '| Type | Severity | Description | Recommendation |' || E'\n';
        v_result := v_result || '|------|----------|-------------|-----------------|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.anomaly_report(p_from_t, p_to_t) ORDER BY severity, anomaly_type LOOP
            v_result := v_result || format('| %s | %s | %s | %s |', v_row.anomaly_type, v_row.severity, v_row.description, v_row.recommendation) || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- Capacity.
    v_result := v_result || '## Capacity' || E'\n\n';
    v_result := v_result || '| Metric | Usage | Capacity | Utilization | Status |' || E'\n';
    v_result := v_result || '|--------|-------|----------|-------------|--------|' || E'\n';
    FOR v_row IN SELECT * FROM pgfr_analyze.capacity_summary(p_from_t, p_to_t) ORDER BY metric LOOP
        v_result := v_result || format('| %s | %s | %s | %s | %s |', v_row.metric, v_row.current_usage, v_row.provisioned_capacity, coalesce(v_row.utilization_pct::text || '%', 'n/a'), v_row.status) || E'\n';
    END LOOP;
    v_result := v_result || E'\n';

    -- Table Hotspots.
    v_result := v_result || '## Table Hotspots' || E'\n\n';
    SELECT count(*) INTO v_count FROM pgfr_analyze.table_hotspots(p_from_t, p_to_t);
    IF v_count = 0 THEN
        v_result := v_result || '(no issues detected)' || E'\n\n';
    ELSE
        v_result := v_result || '| Schema | Table | Issue | Severity | Description |' || E'\n';
        v_result := v_result || '|--------|-------|-------|----------|-------------|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.table_hotspots(p_from_t, p_to_t) LOOP
            v_result := v_result || format('| %s | %s | %s | %s | %s |', v_row.schemaname, v_row.relname, v_row.issue_type, v_row.severity, v_row.description) || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- Index Efficiency + Unused Indexes.
    v_result := v_result || '## Index Efficiency' || E'\n\n';
    SELECT count(*) INTO v_count FROM pgfr_analyze.index_efficiency(p_from_t, p_to_t);
    IF v_count = 0 THEN
        v_result := v_result || '(no index activity in range)' || E'\n\n';
    ELSE
        v_result := v_result || '| Schema | Table | Index | Scans | Selectivity | Size |' || E'\n';
        v_result := v_result || '|--------|-------|-------|-------|-------------|------|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.index_efficiency(p_from_t, p_to_t) LOOP
            v_result := v_result || format('| %s | %s | %s | %s | %s | %s |', v_row.schemaname, v_row.relname, v_row.indexrelname, v_row.idx_scan_delta, coalesce(v_row.selectivity::text || '%', 'n/a'), v_row.index_size) || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    v_result := v_result || '## Rarely-Used Indexes' || E'\n\n';
    SELECT count(*) INTO v_count FROM pgfr_analyze.unused_indexes(p_to_t - p_from_t);
    IF v_count = 0 THEN
        v_result := v_result || '(no drop candidates)' || E'\n\n';
    ELSE
        v_result := v_result || '| Schema | Table | Index | Size | Scans | Recommendation |' || E'\n';
        v_result := v_result || '|--------|-------|-------|------|-------|-----------------|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.unused_indexes(p_to_t - p_from_t) LOOP
            v_result := v_result || format('| %s | %s | %s | %s | %s | %s |', v_row.schemaname, v_row.relname, v_row.indexrelname, v_row.index_size, v_row.scan_delta, v_row.recommendation) || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- Statement Performance: regressions and storms.
    v_result := v_result || '## Query Regressions' || E'\n\n';
    SELECT count(*) INTO v_count FROM pgfr_analyze.detect_regressions(p_to_t - p_from_t);
    IF v_count = 0 THEN
        v_result := v_result || '(no significant regressions)' || E'\n\n';
    ELSE
        v_result := v_result || '| Query | Severity | Baseline (ms) | Current (ms) | Change |' || E'\n';
        v_result := v_result || '|-------|----------|---------------|--------------|--------|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.detect_regressions(p_to_t - p_from_t) ORDER BY change_pct DESC LOOP
            v_result := v_result || format('| %s | %s | %s | %s | %s%% |', left(v_row.query_fingerprint, 60), v_row.severity, v_row.baseline_avg_ms, v_row.current_avg_ms, v_row.change_pct) || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    v_result := v_result || '## Query Storms' || E'\n\n';
    SELECT count(*) INTO v_count FROM pgfr_analyze.detect_query_storms(p_to_t - p_from_t);
    IF v_count = 0 THEN
        v_result := v_result || '(no significant call-rate storms)' || E'\n\n';
    ELSE
        v_result := v_result || '| Query | Storm Type | Severity | Baseline Calls | Recent Calls | Multiplier |' || E'\n';
        v_result := v_result || '|-------|------------|----------|-----------------|---------------|------------|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.detect_query_storms(p_to_t - p_from_t) LOOP
            v_result := v_result || format('| %s | %s | %s | %s | %s | %s |', left(v_row.query_fingerprint, 60), v_row.storm_type, v_row.severity, v_row.baseline_calls, v_row.recent_calls, coalesce(v_row.multiplier::text, 'n/a')) || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- Long-Running Transactions.
    v_result := v_result || '## Long-Running Transactions' || E'\n\n';
    SELECT count(*) INTO v_count FROM pgfr_analyze.long_running_transactions(p_to_t, interval '5 minutes');
    IF v_count = 0 THEN
        v_result := v_result || '(none open longer than 5 minutes)' || E'\n\n';
    ELSE
        v_result := v_result || '| PID | User | App | State | Age | Query |' || E'\n';
        v_result := v_result || '|-----|------|-----|-------|-----|-------|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.long_running_transactions(p_to_t, interval '5 minutes') LOOP
            v_result := v_result || format('| %s | %s | %s | %s | %s | %s |', v_row.pid, v_row.usename, coalesce(v_row.application_name, '-'), v_row.state, v_row.xact_age, left(coalesce(v_row.query, '-'), 40)) || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- Vacuum Progress.
    v_result := v_result || '## Vacuum Progress' || E'\n\n';
    SELECT count(*) INTO v_count FROM pgfr_analyze.vacuum_progress(p_to_t);
    IF v_count = 0 THEN
        v_result := v_result || '(no vacuums in progress)' || E'\n\n';
    ELSE
        v_result := v_result || '| Database | Table | Phase | Scanned | Vacuumed | Dead Tuple Buffer |' || E'\n';
        v_result := v_result || '|----------|-------|-------|---------|----------|-------------------|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.vacuum_progress(p_to_t) LOOP
            v_result := v_result || format('| %s | %s | %s | %s | %s | %s |', v_row.datname, v_row.relname, v_row.phase, coalesce(v_row.pct_scanned::text || '%', 'n/a'), coalesce(v_row.pct_vacuumed::text || '%', 'n/a'), coalesce(v_row.pct_dead_tuple_buffer::text || '%', 'n/a')) || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- WAL Archiver Status.
    v_result := v_result || '## WAL Archiver Status' || E'\n\n';
    SELECT * INTO v_row FROM pgfr_analyze.wal_archiver_status(p_from_t, p_to_t);
    IF v_row.archived_delta IS NULL THEN
        v_result := v_result || '(archiving not enabled or no data in range)' || E'\n\n';
    ELSE
        v_result := v_result || '| Metric | Value |' || E'\n';
        v_result := v_result || '|--------|-------|' || E'\n';
        v_result := v_result || format('| WAL Files Archived | %s |', v_row.archived_delta) || E'\n';
        v_result := v_result || format('| Archive Failures | %s |', v_row.failed_delta) || E'\n';
        IF coalesce(v_row.failed_delta, 0) > 0 THEN
            v_result := v_result || format('| Last Failed WAL | %s |', coalesce(v_row.last_failed_wal, '-')) || E'\n';
            v_result := v_result || format('| Last Failure Time | %s |', coalesce(to_char(v_row.last_failed_time, 'YYYY-MM-DD HH24:MI:SS'), '-')) || E'\n';
        END IF;
        v_result := v_result || E'\n';
    END IF;

    -- Configuration Changes.
    v_result := v_result || '## Configuration Changes' || E'\n\n';
    SELECT count(*) INTO v_count FROM pgfr_analyze.config_changes(p_from_t, p_to_t);
    IF v_count = 0 THEN
        v_result := v_result || '(no changes detected)' || E'\n\n';
    ELSE
        v_result := v_result || '| Parameter | Old Value | New Value | Changed At |' || E'\n';
        v_result := v_result || '|-----------|-----------|-----------|------------|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.config_changes(p_from_t, p_to_t) LOOP
            v_result := v_result || format('| %s | %s | %s | %s |', v_row.name, coalesce(v_row.old_setting, '-'), coalesce(v_row.new_setting, '-'), to_char(v_row.changed_at, 'YYYY-MM-DD HH24:MI:SS')) || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    RETURN v_result;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.report(timestamptz, timestamptz) IS
    'Human- and AI-legible markdown report for the window [p_from_t, p_to_t], composing coverage()/coverage_gaps(), anomaly_report(), capacity_summary(), table_hotspots(), index_efficiency(), unused_indexes(), detect_regressions(), detect_query_storms(), long_running_transactions(), vacuum_progress(), wal_archiver_status(), and config_changes(). Wait Event Summary, Lock Contention, and Role Configuration Changes (v1 sections) are not included -- see this function''s header comment for why.';

CREATE OR REPLACE FUNCTION pgfr_analyze.report(p_lookback interval)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT pgfr_analyze.report(clock_timestamp() - p_lookback, clock_timestamp());
$$;

COMMENT ON FUNCTION pgfr_analyze.report(interval) IS
    'Convenience overload: report(interval ''1 hour'') instead of report(clock_timestamp() - interval ''1 hour'', clock_timestamp()).';
