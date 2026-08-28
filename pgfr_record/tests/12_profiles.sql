-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- profiles, apply_profile(), enable(),
-- disable(), health_check() (§9)
-- =============================================================================

BEGIN;
SELECT plan(25);

SELECT has_table('pgfr_record', 'profiles', 'Table pgfr_record.profiles should exist');
SELECT has_table('pgfr_record', 'profile_tiers', 'Table pgfr_record.profile_tiers should exist');
SELECT has_function('pgfr_record', 'apply_profile', 'Function pgfr_record.apply_profile should exist');
SELECT has_function('pgfr_record', 'enable', 'Function pgfr_record.enable should exist');
SELECT has_function('pgfr_record', 'disable', 'Function pgfr_record.disable should exist');
SELECT has_function('pgfr_record', 'health_check', 'Function pgfr_record.health_check should exist');

SELECT is((SELECT count(*)::int FROM pgfr_record.profiles), 2, 'the default and troubleshooting profiles should be seeded');

-- ---------------------------------------------------------------------------
-- _interval_to_cron() / _cron_schedule_to_interval() round-trip.
-- ---------------------------------------------------------------------------
SELECT is(pgfr_record._interval_to_cron(interval '1 minute'), '*/1 * * * *', '1-minute interval should render as */1 * * * *');
SELECT is(pgfr_record._interval_to_cron(interval '5 minutes'), '*/5 * * * *', '5-minute interval should render as */5 * * * *');
SELECT is(pgfr_record._interval_to_cron(interval '20 seconds'), '20 seconds', 'sub-minute interval should render as the pg_cron ''N seconds'' literal');
SELECT is(pgfr_record._cron_schedule_to_interval('*/5 * * * *'), interval '5 minutes', '_cron_schedule_to_interval should parse a */N minute-cron schedule');
SELECT is(pgfr_record._cron_schedule_to_interval('20 seconds'), interval '20 seconds', '_cron_schedule_to_interval should parse an ''N seconds'' schedule');

-- ---------------------------------------------------------------------------
-- apply_profile(): schedules the four tier jobs; re-applying a different
-- profile reschedules them (no separate "active profile" state to drift).
-- ---------------------------------------------------------------------------
SELECT throws_ok($$SELECT pgfr_record.apply_profile('does_not_exist')$$, 'P0001', NULL, 'apply_profile() on an unknown profile should raise an exception');

SELECT lives_ok($$SELECT pgfr_record.apply_profile('default')$$, 'apply_profile(''default'') should succeed');
SELECT is((SELECT schedule FROM cron.job WHERE jobname = 'pgfr_tier_fast'), '*/1 * * * *', 'the fast tier job should be scheduled per the default profile''s 1-minute interval');
SELECT ok((SELECT command FROM cron.job WHERE jobname = 'pgfr_tier_fast') LIKE '%run_tier(''fast''%', 'the fast tier job''s command should invoke run_tier(''fast'', ...)');

SELECT lives_ok($$SELECT pgfr_record.apply_profile('troubleshooting')$$, 'apply_profile(''troubleshooting'') should succeed');
SELECT is((SELECT schedule FROM cron.job WHERE jobname = 'pgfr_tier_fast'), '20 seconds', 're-applying a different profile should reschedule the same job to its new cadence');

-- ---------------------------------------------------------------------------
-- enable() / disable() / health_check().
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.enable()$$, 'enable() should succeed');
SELECT is(
    (SELECT count(*)::int FROM cron.job WHERE jobname IN ('pgfr_tier_fast','pgfr_tier_medium','pgfr_tier_slow','pgfr_tier_on_change','pgfr_maintain_partitions') AND active),
    5,
    'enable() should leave all four tier jobs and the maintenance job scheduled and active'
);
SELECT ok(
    (SELECT bool_and(status = 'ok') FROM pgfr_record.health_check() WHERE check_name LIKE 'cron_job:%'),
    'health_check() should report every cron_job check as ok after enable()'
);

SELECT lives_ok($$SELECT pgfr_record.disable()$$, 'disable() should succeed');
SELECT is(
    (SELECT count(*)::int FROM cron.job WHERE jobname IN ('pgfr_tier_fast','pgfr_tier_medium','pgfr_tier_slow','pgfr_tier_on_change','pgfr_maintain_partitions')),
    0,
    'disable() should unschedule all four tier jobs and the maintenance job'
);
SELECT ok(
    (SELECT bool_and(status = 'missing') FROM pgfr_record.health_check() WHERE check_name LIKE 'cron_job:%'),
    'health_check() should report every cron_job check as missing after disable()'
);

-- ---------------------------------------------------------------------------
-- The overrun invariant is a real CHECK constraint, not a convention
-- (§5, §10.1 acceptance criterion 6).
-- ---------------------------------------------------------------------------
INSERT INTO pgfr_record.profiles (profile_name, lock_timeout, section_timeout)
VALUES ('test_check_profile', interval '100 ms', interval '250 ms');

SELECT throws_ok(
    $$INSERT INTO pgfr_record.profile_tiers (profile_name, cadence_tier, tier_interval, job_timeout)
      VALUES ('test_check_profile', 'fast', interval '1 minute', interval '1 minute')$$,
    '23514', NULL,
    'a profile_tiers row with job_timeout >= tier_interval should violate the CHECK constraint'
);

SELECT * FROM finish();
ROLLBACK;
