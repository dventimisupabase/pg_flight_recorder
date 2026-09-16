-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- run_tier() collector core (§5)
-- =============================================================================
-- pg_settings (not pg_stat_all_tables) is used for the debounce/anchor
-- round-trip below: Group B targets are subject to self-observation
-- (§4.6) -- the collector's own INSERTs into e.g. a_pg_stat_all_tables
-- change that very table's stats between two captures in the same
-- transaction, which would make a "nothing changed" assumption flaky.
-- pg_settings has no such self-observation feedback loop.

BEGIN;
SELECT plan(24);

SELECT has_function('pgfr_record', 'run_tier', 'Function pgfr_record.run_tier should exist');
SELECT has_function('pgfr_record', '_interval_ms_literal', 'Function pgfr_record._interval_ms_literal should exist');
SELECT has_function('pgfr_record', '_default_job_timeout', 'Function pgfr_record._default_job_timeout should exist');

SELECT is(pgfr_record._interval_ms_literal(interval '250 ms'), '250ms', '_interval_ms_literal should render 250ms literally');
SELECT is(pgfr_record._interval_ms_literal(interval '100 ms'), '100ms', '_interval_ms_literal should render 100ms literally');
SELECT ok(
    pgfr_record._default_job_timeout('fast') < interval '1 minute',
    'the fast tier''s default job timeout should stay safely under its 1-minute interval'
);

-- ---------------------------------------------------------------------------
-- Single stamp + ledger wiring, on the fast tier.
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should execute without error');
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.ledger_runs WHERE tier = 'fast'),
    1,
    'one run_tier(''fast'') call should append exactly one ledger_runs row'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.ledger_captures lc JOIN pgfr_record.ledger_runs lr ON lr.run_id = lc.run_id WHERE lr.tier = 'fast'),
    (SELECT count(*)::int FROM pgfr_record.capture_plan WHERE cadence_tier = 'fast'),
    'the run should record one ledger_captures row per fast-tier capture_plan target'
);
SELECT ok(
    (SELECT bool_and(outcome = 'ok') FROM pgfr_record.ledger_captures lc JOIN pgfr_record.ledger_runs lr ON lr.run_id = lc.run_id WHERE lr.tier = 'fast'),
    'every fast-tier target should succeed on a clean install'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.a_pg_stat_archiver),
    1,
    'pg_stat_archiver (non-debounced) should get exactly one appended row from the first fast-tier run'
);
SELECT is(
    (SELECT captured_at FROM pgfr_record.a_pg_stat_archiver),
    (SELECT captured_at FROM pgfr_record.a_pg_stat_wal),
    'single-stamp rule: two targets captured in the same tier run should share the identical captured_at'
);

-- ---------------------------------------------------------------------------
-- Debounce + anchor round-trip, on the on_change tier / pg_settings.
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.run_tier('on_change')$$, 'first run_tier(''on_change'') should execute without error');

SELECT count(*)::int AS first_settings_count FROM pgfr_record.a_pg_settings \gset

SELECT ok(:first_settings_count > 0, 'the first on_change capture should append rows for pg_settings');
SELECT is(
    (SELECT was_anchor FROM pgfr_record.ledger_captures WHERE source_view = 'pg_catalog.pg_settings' ORDER BY captured_at DESC LIMIT 1),
    true,
    'the first-ever capture of a debounced target should be recorded as an anchor'
);

SELECT lives_ok($$SELECT pgfr_record.run_tier('on_change')$$, 'second run_tier(''on_change'') should execute without error');
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.a_pg_settings),
    :first_settings_count,
    'a second capture with nothing changed should append zero new rows (debounce anti-join)'
);
SELECT is(
    (SELECT was_anchor FROM pgfr_record.ledger_captures WHERE source_view = 'pg_catalog.pg_settings' ORDER BY captured_at DESC LIMIT 1),
    false,
    'the second capture within the same partition should not be an anchor'
);
SELECT is(
    (SELECT rows_appended FROM pgfr_record.ledger_captures WHERE source_view = 'pg_catalog.pg_settings' ORDER BY captured_at DESC LIMIT 1),
    0,
    'the second, unchanged capture should report zero rows_appended'
);

-- ---------------------------------------------------------------------------
-- Failure isolation (§5): one target's error cannot fail the tier, and is
-- recorded, not swallowed.
-- ---------------------------------------------------------------------------
SELECT lives_ok(
    $$UPDATE pgfr_record.capture_plan
      SET capture_select_sql = 'SELECT NULL::jsonb AS key, NULL::bigint AS key_hash, 1::bigint AS row_hash, jsonb_build_array(nonexistent_column_xyz) AS payload FROM pg_catalog.pg_stat_wal_receiver'
      WHERE source_view = 'pg_catalog.pg_stat_wal_receiver'$$,
    'corrupting one target''s cached capture SQL should succeed (capture_plan is regenerable config, not record)'
);
SELECT lives_ok(
    $$SELECT pgfr_record.run_tier('fast')$$,
    'run_tier(''fast'') should still complete even though one target''s capture SQL is broken'
);
SELECT is(
    (SELECT outcome FROM pgfr_record.ledger_captures lc JOIN pgfr_record.ledger_runs lr ON lr.run_id = lc.run_id
     WHERE lr.tier = 'fast' AND lc.source_view = 'pg_catalog.pg_stat_wal_receiver'
     ORDER BY lr.finished_at DESC LIMIT 1),
    'error',
    'the target with broken capture SQL should be recorded as outcome = error'
);
SELECT ok(
    (SELECT detail FROM pgfr_record.ledger_captures lc JOIN pgfr_record.ledger_runs lr ON lr.run_id = lc.run_id
     WHERE lr.tier = 'fast' AND lc.source_view = 'pg_catalog.pg_stat_wal_receiver'
     ORDER BY lr.finished_at DESC LIMIT 1) IS NOT NULL,
    'the error outcome should carry sqlerrm detail, not a silent failure'
);
SELECT is(
    (SELECT outcome FROM pgfr_record.ledger_captures lc JOIN pgfr_record.ledger_runs lr ON lr.run_id = lc.run_id
     WHERE lr.tier = 'fast' AND lc.source_view = 'pg_catalog.pg_stat_archiver'
     ORDER BY lr.finished_at DESC LIMIT 1),
    'ok',
    'a sibling target in the same tier run should still succeed despite another target''s failure'
);

SELECT * FROM finish();
ROLLBACK;
