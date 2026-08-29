-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- preflight_check(), preflight_check_with_summary()
-- =============================================================================
-- Both functions read live catalog state (pg_settings, pg_stat_activity,
-- pg_extension) rather than captured history, so every test container
-- (which always has pg_cron and pg_stat_statements installed per test.sh)
-- exercises the same GO path. The NO-GO/CAUTION branches are simple,
-- independently-reviewable boolean/threshold checks on that same live
-- state; forcing them here would mean uninstalling pg_cron or
-- pg_stat_statements from a shared test container, which would break
-- pgfr_record itself (pg_cron is a hard install-time dependency).

BEGIN;
SELECT plan(10);

SELECT has_function('pgfr_analyze', 'preflight_check', 'Function pgfr_analyze.preflight_check should exist');
SELECT has_function('pgfr_analyze', 'preflight_check_with_summary', 'Function pgfr_analyze.preflight_check_with_summary should exist');

SELECT results_eq(
    $$SELECT check_name FROM pgfr_analyze.preflight_check() ORDER BY check_name$$,
    $$VALUES ('Connection Headroom'), ('Scheduling (pg_cron)'), ('Safety Mechanisms'), ('Storage Overhead'), ('System Resources'), ('pg_stat_statements Budget') ORDER BY 1$$,
    'preflight_check() should return exactly the six expected checks'
);

SELECT ok(
    (SELECT bool_and(status IN ('GO', 'CAUTION', 'NO-GO')) FROM pgfr_analyze.preflight_check()),
    'every preflight_check() row should carry a GO/CAUTION/NO-GO status'
);

-- pg_cron and pg_stat_statements are both installed in every test
-- container (test.sh's setup), so this container is expected to be clean.
SELECT is(
    (SELECT status FROM pgfr_analyze.preflight_check() WHERE check_name = 'Scheduling (pg_cron)'),
    'GO',
    'Scheduling (pg_cron) should be GO when pg_cron is installed'
);
SELECT is(
    (SELECT status FROM pgfr_analyze.preflight_check() WHERE check_name = 'pg_stat_statements Budget'),
    'GO',
    'pg_stat_statements Budget should be GO in a container with pg_stat_statements installed and a comfortable pg_stat_statements.max'
);

SELECT is(
    (SELECT check_name FROM pgfr_analyze.preflight_check_with_summary() ORDER BY check_name = '=== SUMMARY ===' DESC LIMIT 1),
    '=== SUMMARY ===',
    'preflight_check_with_summary() should append a === SUMMARY === row'
);
SELECT is(
    (SELECT status FROM pgfr_analyze.preflight_check_with_summary() WHERE check_name = '=== SUMMARY ==='),
    'READY',
    'preflight_check_with_summary() should report READY when every underlying check is GO'
);

-- ---------------------------------------------------------------------------
-- Should not write anywhere.
-- ---------------------------------------------------------------------------
SET TRANSACTION READ ONLY;
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.preflight_check()) >= 0,
    'preflight_check() should execute successfully inside a hard READ ONLY transaction'
);
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.preflight_check_with_summary()) >= 0,
    'preflight_check_with_summary() should execute successfully inside a hard READ ONLY transaction'
);

SELECT * FROM finish();
ROLLBACK;
