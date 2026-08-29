-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- summary_report(): a structured (section, metric, value, interpretation)
-- table composing every analysis function built in this milestone into one
-- queryable overview, for a window [p_from_t, p_to_t]. report() renders the
-- same underlying functions as markdown prose; this is the machine-readable
-- form.

CREATE OR REPLACE FUNCTION pgfr_analyze.summary_report(p_from_t timestamptz, p_to_t timestamptz)
RETURNS TABLE(section text, metric text, value text, interpretation text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_elapsed_seconds  numeric := extract(epoch FROM (p_to_t - p_from_t));
    v_cov_line         text;
    v_min_ratio        numeric;
    v_anomaly_count    bigint;
    v_worst_severity   text;
    v_capacity_worst   text;
    v_hotspot_count    bigint;
    v_unused_idx_count bigint;
    v_long_xact_count  bigint;
    v_vacuum_count     bigint;
    v_archiver         record;
    v_config_count     bigint;
BEGIN
    section := 'OVERVIEW';
    metric := 'Time Window';
    value := format('%s to %s', p_from_t, p_to_t);
    interpretation := format('%s seconds elapsed', round(v_elapsed_seconds, 1));
    RETURN NEXT;

    SELECT string_agg(format('%s/%s %s (%s%%)', c.observed_runs, round(c.expected_runs, 1), c.cadence_tier, round(c.coverage_ratio * 100, 1)), ', ' ORDER BY c.cadence_tier),
           min(c.coverage_ratio)
    INTO v_cov_line, v_min_ratio
    FROM pgfr_analyze.coverage(p_from_t, p_to_t) c;

    metric := 'Data Coverage';
    value := coalesce(v_cov_line, 'no expected ticks in window');
    interpretation := CASE
        WHEN v_min_ratio IS NULL THEN 'No tiers scheduled in this window'
        WHEN v_min_ratio < 0.9 THEN 'WARNING: coverage below 90% for at least one tier; conclusions below are qualified accordingly'
        ELSE 'OK'
    END;
    RETURN NEXT;

    SELECT count(*), max(severity) FILTER (WHERE severity = 'HIGH') INTO v_anomaly_count, v_worst_severity FROM pgfr_analyze.anomaly_report(p_from_t, p_to_t);
    metric := 'Anomalies Detected';
    value := v_anomaly_count::text;
    interpretation := CASE
        WHEN v_anomaly_count = 0 THEN 'No issues detected'
        WHEN v_worst_severity = 'HIGH' THEN 'HIGH-severity issues present -- review anomaly_report()'
        ELSE 'Minor issues -- review anomaly_report()'
    END;
    RETURN NEXT;

    SELECT string_agg(DISTINCT status, ', ') INTO v_capacity_worst FROM pgfr_analyze.capacity_summary(p_from_t, p_to_t) WHERE status IN ('warning', 'critical');
    section := 'CAPACITY';
    metric := 'Dimensions Needing Attention';
    value := coalesce(v_capacity_worst, 'none');
    interpretation := CASE WHEN v_capacity_worst IS NULL THEN 'All capacity dimensions healthy' ELSE 'Review capacity_summary() for details' END;
    RETURN NEXT;

    SELECT count(*) INTO v_hotspot_count FROM pgfr_analyze.table_hotspots(p_from_t, p_to_t);
    section := 'TABLES & INDEXES';
    metric := 'Table Hotspots';
    value := v_hotspot_count::text;
    interpretation := CASE WHEN v_hotspot_count = 0 THEN 'No table-level issues detected' ELSE 'Review table_hotspots() for details' END;
    RETURN NEXT;

    -- unused_indexes() only takes a lookback interval (it always measures
    -- up to clock_timestamp()), so this approximates [p_from_t, p_to_t]
    -- with an equal-length window ending now; exact only when p_to_t is
    -- itself close to now(), which is the typical call pattern.
    SELECT count(*) INTO v_unused_idx_count FROM pgfr_analyze.unused_indexes(p_to_t - p_from_t);
    metric := 'Rarely-Used Indexes';
    value := v_unused_idx_count::text;
    interpretation := CASE WHEN v_unused_idx_count = 0 THEN 'No drop candidates' ELSE 'Review unused_indexes() for drop candidates' END;
    RETURN NEXT;

    SELECT count(*) INTO v_long_xact_count FROM pgfr_analyze.long_running_transactions(p_to_t, interval '5 minutes');
    section := 'ACTIVITY';
    metric := 'Long-Running Transactions';
    value := v_long_xact_count::text;
    interpretation := CASE WHEN v_long_xact_count = 0 THEN 'None open longer than 5 minutes' ELSE 'Review long_running_transactions() for details' END;
    RETURN NEXT;

    SELECT count(*) INTO v_vacuum_count FROM pgfr_analyze.vacuum_progress(p_to_t);
    metric := 'VACUUMs In Flight';
    value := v_vacuum_count::text;
    interpretation := CASE WHEN v_vacuum_count = 0 THEN 'None in progress' ELSE 'Review vacuum_progress() for details' END;
    RETURN NEXT;

    SELECT * INTO v_archiver FROM pgfr_analyze.wal_archiver_status(p_from_t, p_to_t);
    IF v_archiver.archived_delta IS NOT NULL THEN
        metric := 'WAL Archiving';
        value := format('%s archived, %s failed', v_archiver.archived_delta, v_archiver.failed_delta);
        interpretation := CASE WHEN coalesce(v_archiver.failed_delta, 0) > 0 THEN 'WARNING: archive failures in window' ELSE 'OK' END;
        RETURN NEXT;
    END IF;

    SELECT count(*) INTO v_config_count FROM pgfr_analyze.config_changes(p_from_t, p_to_t);
    section := 'CONFIGURATION';
    metric := 'Parameter Changes';
    value := v_config_count::text;
    interpretation := CASE WHEN v_config_count = 0 THEN 'No configuration changes in window' ELSE 'Review config_changes() for details' END;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.summary_report(timestamptz, timestamptz) IS
    'A structured (section, metric, value, interpretation) overview composing coverage(), anomaly_report(), capacity_summary(), table_hotspots(), unused_indexes(), long_running_transactions(), vacuum_progress(), wal_archiver_status(), and config_changes() for the window [p_from_t, p_to_t]. report() renders the same underlying functions as markdown prose; this is the machine-readable form. Sections: OVERVIEW, CAPACITY, TABLES & INDEXES, ACTIVITY, CONFIGURATION.';
