-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- check_alerts(): an opinionated escalation layer over pgfr_record's own
-- facts. pgfr_record.health_check() reports structural facts against fixed
-- thresholds, judgment-free by design; check_alerts() is where the
-- opinion belongs, turning every non-ok health_check() row into an alert
-- with a severity and a recommendation, plus a storage-size opinion that
-- health_check() has no basis to make on its own. Takes no parameters:
-- every underlying signal (health_check()'s own fixed 1-hour ledger-miss
-- window, a live storage read) is already anchored to "right now".

CREATE OR REPLACE FUNCTION pgfr_analyze.check_alerts()
RETURNS TABLE(alert_type text, severity text, message text, triggered_at timestamptz, recommendation text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_now            timestamptz := clock_timestamp();
    v_row            record;
    v_storage_bytes  numeric;
    v_storage_threshold numeric := 8000::bigint * 1024 * 1024; -- 8000 MiB
BEGIN
    FOR v_row IN SELECT * FROM pgfr_record.health_check() WHERE status <> 'ok' LOOP
        triggered_at := v_now;
        IF v_row.check_name LIKE 'cron_job:%' THEN
            alert_type := 'CRON_JOB_MISSING';
            severity := 'CRITICAL';
            message := format('%s: %s', v_row.check_name, v_row.detail);
            recommendation := 'pgfr_record is not scheduled to capture. Run pgfr_record.enable() to (re)schedule it.';
        ELSIF v_row.check_name LIKE 'last_capture:%' THEN
            alert_type := 'STALE_DATA';
            severity := CASE WHEN v_row.status = 'never' THEN 'CRITICAL' ELSE 'WARNING' END;
            message := format('%s: %s', v_row.check_name, v_row.detail);
            recommendation := 'Check that this tier''s pg_cron job is active and recent runs succeeded (SELECT * FROM pgfr_record.ledger_runs ORDER BY finished_at DESC).';
        ELSIF v_row.check_name = 'ledger_miss_rate_1h' THEN
            alert_type := 'CAPTURE_FAILURES';
            severity := 'WARNING';
            message := v_row.detail;
            recommendation := 'Inspect pgfr_record.ledger_captures for recent non-ok outcomes and their detail column.';
        ELSIF v_row.check_name LIKE 'partitions:%' THEN
            alert_type := 'PARTITION_MAINTENANCE_NEEDED';
            severity := 'WARNING';
            message := format('%s: %s', v_row.check_name, v_row.detail);
            recommendation := 'Run pgfr_record.maintain_partitions(); if this persists, confirm the pgfr_maintain_partitions cron job is scheduled and active.';
        ELSE
            CONTINUE;
        END IF;
        RETURN NEXT;
    END LOOP;

    -- Computed directly rather than via self_overhead(): that function
    -- requires a minted payload schema for pg_statio_all_tables (needed
    -- for its recorder_block_share metric), which would make this specific
    -- check unusable on a system too fresh to have run the slow tier yet --
    -- exactly the kind of system check_alerts() needs to work on.
    SELECT sum(pg_total_relation_size(c.oid)) INTO v_storage_bytes
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('pgfr_record', 'pgfr_analyze') AND c.relkind IN ('r', 'm');

    IF v_storage_bytes IS NOT NULL AND v_storage_bytes >= v_storage_threshold THEN
        alert_type := 'STORAGE_SIZE_HIGH';
        severity := 'WARNING';
        message := format('pgfr_record/pgfr_analyze schemas are using %s', pg_size_pretty(v_storage_bytes));
        triggered_at := v_now;
        recommendation := 'Review retention settings in pgfr_record.manifest, or disable lower-value targets, to bring storage back down.';
        RETURN NEXT;
    END IF;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.check_alerts() IS
    'Alerts on the recorder''s own health: every non-ok pgfr_record.health_check() row (cron job missing, tier data stale/never captured, capture failure rate over the last hour, or partition maintenance overdue) escalated to an alert_type/severity/recommendation, plus a storage-size opinion (>= 8000 MiB, read live from pg_total_relation_size over the pgfr_record/pgfr_analyze schemas). Empty when everything is healthy.';
