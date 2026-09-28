-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- check_alerts()
-- =============================================================================
-- test.sh deactivates every pgfr_ cron job before running the pgTAP suite
-- (to avoid a live scheduler racing the tests), so pgfr_record.health_check()
-- always reports every cron_job row as 'missing' here -- CRON_JOB_MISSING is
-- therefore an expected, deterministic finding in this environment, not
-- something to avoid triggering.

BEGIN;
SELECT plan(10);

SELECT has_function('pgfr_analyze', 'check_alerts', 'Function pgfr_analyze.check_alerts should exist');

-- ---------------------------------------------------------------------------
-- Fresh state (before any tier has run in this test's own transaction):
-- CRON_JOB_MISSING (deactivated by test.sh) and STALE_DATA ('never') both
-- present.
-- ---------------------------------------------------------------------------
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.check_alerts() WHERE alert_type = 'CRON_JOB_MISSING') >= 5,
    'check_alerts() should report CRON_JOB_MISSING for all 5 pgfr_ jobs (4 tiers + maintenance) while cron is deactivated'
);
SELECT ok(
    (SELECT bool_and(severity = 'CRITICAL') FROM pgfr_analyze.check_alerts() WHERE alert_type = 'CRON_JOB_MISSING'),
    'every CRON_JOB_MISSING alert should be CRITICAL'
);
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.check_alerts() WHERE alert_type = 'STALE_DATA' AND message LIKE '%no run recorded yet%') > 0,
    'check_alerts() should report STALE_DATA for tiers that have never run'
);

-- ---------------------------------------------------------------------------
-- After running every tier, STALE_DATA should clear for all of them
-- (CRON_JOB_MISSING persists -- cron is still deactivated).
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should succeed');
SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'run_tier(''medium'') should succeed');
SELECT lives_ok($$SELECT pgfr_record.run_tier('slow')$$, 'run_tier(''slow'') should succeed');
SELECT lives_ok($$SELECT pgfr_record.run_tier('on_change')$$, 'run_tier(''on_change'') should succeed');

SELECT is(
    (SELECT count(*) FROM pgfr_analyze.check_alerts() WHERE alert_type = 'STALE_DATA')::int,
    0,
    'check_alerts() should report no STALE_DATA once every tier has just run'
);

-- ---------------------------------------------------------------------------
-- Should not write anywhere.
-- ---------------------------------------------------------------------------
SET TRANSACTION READ ONLY;
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.check_alerts()) >= 0,
    'check_alerts() should execute successfully inside a hard READ ONLY transaction'
);

SELECT * FROM finish();
ROLLBACK;
