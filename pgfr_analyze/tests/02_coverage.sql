-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- coverage(), coverage_gaps()
-- =============================================================================
-- test.sh's own harness deactivates every pgfr_ cron job before running
-- pgTAP (closing a real race with background pg_cron firing mid-test), so
-- this file never assumes an ambient active/inactive starting state for
-- cron.job -- every scenario below sets it explicitly first.

BEGIN;
SELECT plan(14);

SELECT has_function('pgfr_analyze', 'coverage', ARRAY['timestamptz', 'timestamptz'], 'Function pgfr_analyze.coverage(timestamptz, timestamptz) should exist');
SELECT has_function('pgfr_analyze', 'coverage', ARRAY['interval'], 'Function pgfr_analyze.coverage(interval) should exist');
SELECT has_function('pgfr_analyze', 'coverage_gaps', ARRAY['timestamptz', 'timestamptz'], 'Function pgfr_analyze.coverage_gaps(timestamptz, timestamptz) should exist');
SELECT has_function('pgfr_analyze', 'coverage_gaps', ARRAY['interval'], 'Function pgfr_analyze.coverage_gaps(interval) should exist');

-- ---------------------------------------------------------------------------
-- coverage(): a real run_tier('fast') call should be counted.
-- ---------------------------------------------------------------------------
UPDATE cron.job SET active = true WHERE jobname = 'pgfr_tier_fast';

SELECT clock_timestamp() AS t0 \gset before_
SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should capture successfully');
SELECT clock_timestamp() AS t1 \gset after_

SELECT is(
    (SELECT observed_runs FROM pgfr_analyze.coverage(:'before_t0'::timestamptz, :'after_t1'::timestamptz) WHERE cadence_tier = 'fast'),
    1::bigint,
    'coverage() should count the one real fast-tier run inside the window'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_analyze.coverage(:'before_t0'::timestamptz, :'after_t1'::timestamptz)),
    4,
    'coverage() should return exactly one row per cadence tier'
);
SELECT ok(
    (SELECT observed_runs FROM pgfr_analyze.coverage(interval '1 hour') WHERE cadence_tier = 'fast') >= 1,
    'coverage(interval) should see the fast-tier run within the trailing window'
);

-- ---------------------------------------------------------------------------
-- coverage_gaps(): tier scheduled and active, window with no real captures.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT attributed_reason FROM pgfr_analyze.coverage_gaps(now() - interval '30 minutes', now() - interval '20 minutes') WHERE cadence_tier = 'fast' LIMIT 1),
    'unknown',
    'a gap while the tier job is scheduled and active should be attributed unknown'
);
SELECT ok(
    (SELECT missed_ticks FROM pgfr_analyze.coverage_gaps(now() - interval '30 minutes', now() - interval '20 minutes') WHERE cadence_tier = 'fast' LIMIT 1) > 0,
    'an active-tier gap should report a real missed_ticks count'
);

-- ---------------------------------------------------------------------------
-- coverage_gaps(): tier scheduled but deactivated (mirrors test.sh's own
-- deactivate_pgfr_cron pattern, not disable()'s full unschedule).
-- ---------------------------------------------------------------------------
UPDATE cron.job SET active = false WHERE jobname = 'pgfr_tier_fast';

SELECT is(
    (SELECT attributed_reason FROM pgfr_analyze.coverage_gaps(now() - interval '10 minutes', now() + interval '10 minutes') WHERE cadence_tier = 'fast' LIMIT 1),
    'cron_inactive',
    'a gap while the tier job is scheduled but inactive should be attributed cron_inactive'
);
SELECT ok(
    (SELECT missed_ticks FROM pgfr_analyze.coverage_gaps(now() - interval '10 minutes', now() + interval '10 minutes') WHERE cadence_tier = 'fast' LIMIT 1) > 0,
    'a deactivated-but-scheduled tier still has a resolvable interval, so missed_ticks should be a real count'
);

-- ---------------------------------------------------------------------------
-- coverage_gaps(): tier fully unscheduled (disable()). No interval to grid
-- against, so the whole window is one gap with a NULL tick count rather
-- than the tier silently vanishing from the result.
-- ---------------------------------------------------------------------------
SELECT pgfr_record.disable();

SELECT is(
    (SELECT count(*)::int FROM pgfr_analyze.coverage_gaps(now() - interval '10 minutes', now() + interval '10 minutes') WHERE cadence_tier = 'fast'),
    1,
    'a fully unscheduled tier should produce exactly one gap row spanning the whole window'
);
SELECT is(
    (SELECT missed_ticks FROM pgfr_analyze.coverage_gaps(now() - interval '10 minutes', now() + interval '10 minutes') WHERE cadence_tier = 'fast' LIMIT 1),
    NULL,
    'an unscheduled tier has no resolvable interval, so missed_ticks should be NULL rather than a fabricated count'
);

SELECT * FROM finish();
ROLLBACK;
