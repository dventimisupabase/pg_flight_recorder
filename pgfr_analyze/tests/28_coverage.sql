-- =============================================================================
-- pgfr_analyze pgTAP Tests: coverage() and gap accounting (Issue #100)
-- =============================================================================
-- coverage() reports expected vs observed collection ticks per collector at
-- the fixed 60s cadence; coverage_gaps() lists each gap with an attributed
-- reason (circuit_breaker, load_shedding, cron_inactive, restart,
-- retention_horizon, unknown). Fixtures use synthetic windows far in the past
-- (seconds since pgfr_record.epoch(), like 18_ring_rollups.sql) so the live
-- cron jobs cannot write into them, and everything rolls back.
--
-- Window layout (seconds since epoch):
--   W1 = [600000, 600600): fully populated for all three collectors
--   W2 = [700200, 700800): ring missing minutes 4 and 5, with matching
--        circuit-breaker skip rows in collection_stats
--   The retention window [598200, 600600) starts 30 minutes before the oldest
--   fixture tick, so its leading portion predates all retained evidence.
-- =============================================================================

BEGIN;
SELECT plan(15);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    v_epoch timestamptz := pgfr_record.epoch();
    v_wid   smallint;
    v_b1    integer := 600000;
    v_b2    integer := 700200;
    v_i     integer;
    v_ts    integer;
BEGIN
    v_wid := pgfr_record._register_wait('active', '__pgfr_cov__', '__wait__');

    -- Deterministic retention floors: earlier suite files leave synthetic
    -- rows at tiny sample_ts values (e.g. test_ring_buffer.sql inserts
    -- sample_ts = 1), which would drag min(sample_ts) below the fixture and
    -- defeat the retention_horizon assertion. Everything here rolls back.
    DELETE FROM pgfr_record.wait_samples WHERE sample_ts < 800000;
    DELETE FROM pgfr_record.snapshots
    WHERE captured_at < v_epoch + 800000 * interval '1 second';
    DELETE FROM pgfr_record.consumption_snapshots_v2
    WHERE captured_at < v_epoch + 800000 * interval '1 second';

    PERFORM pgfr_record._ensure_partition('consumption_snapshots_v2',
        (v_epoch + v_b1 * interval '1 second')::date, 'snapshot_id, sample_ts desc');
    PERFORM pgfr_record._ensure_partition('consumption_snapshots_v2',
        (v_epoch + v_b2 * interval '1 second')::date, 'snapshot_id, sample_ts desc');

    FOR v_i IN 0..9 LOOP
        -- W1: every collector observes every minute (1s of jitter, like real ticks)
        v_ts := v_b1 + v_i * 60 + 1;
        INSERT INTO pgfr_record.wait_samples (sample_ts, datid, active_count, data, slot)
        VALUES (v_ts, 0, 1, ARRAY[-v_wid, 1, 0], 0);
        INSERT INTO pgfr_record.snapshots (captured_at, pg_version)
        VALUES (v_epoch + v_ts * interval '1 second', 170000);
        INSERT INTO pgfr_record.consumption_snapshots_v2
            (snapshot_id, sample_ts, captured_at, pg_version, datname)
        VALUES (-900000 - v_i, v_ts, v_epoch + v_ts * interval '1 second', 170000,
                current_database());

        -- W2: ring skips minutes 4 and 5; snapshot and consumption stay full
        v_ts := v_b2 + v_i * 60 + 1;
        IF v_i NOT IN (4, 5) THEN
            INSERT INTO pgfr_record.wait_samples (sample_ts, datid, active_count, data, slot)
            VALUES (v_ts, 0, 1, ARRAY[-v_wid, 1, 0], 0);
        END IF;
        INSERT INTO pgfr_record.snapshots (captured_at, pg_version)
        VALUES (v_epoch + v_ts * interval '1 second', 170000);
        INSERT INTO pgfr_record.consumption_snapshots_v2
            (snapshot_id, sample_ts, captured_at, pg_version, datname)
        VALUES (-910000 - v_i, v_ts, v_epoch + v_ts * interval '1 second', 170000,
                current_database());
    END LOOP;

    -- Circuit-breaker evidence for W2's two missing ring minutes
    INSERT INTO pgfr_record.collection_stats
        (collection_type, started_at, completed_at, skipped, skipped_reason, skip_kind)
    VALUES
        ('sample', v_epoch + (v_b2 + 4 * 60 + 1) * interval '1 second',
         v_epoch + (v_b2 + 4 * 60 + 1) * interval '1 second', true,
         'Circuit breaker tripped - recent runs exceeded threshold', 'circuit_breaker'),
        ('sample', v_epoch + (v_b2 + 5 * 60 + 1) * interval '1 second',
         v_epoch + (v_b2 + 5 * 60 + 1) * interval '1 second', true,
         'Circuit breaker tripped - recent runs exceeded threshold', 'circuit_breaker');
END $$;

-- -----------------------------------------------------------------------------
-- 1. Shape
-- -----------------------------------------------------------------------------

SELECT has_function('pgfr_analyze', 'coverage', ARRAY['timestamptz', 'timestamptz'],
    'coverage(start, end) exists');
SELECT has_function('pgfr_analyze', 'coverage', ARRAY['interval'],
    'coverage(interval) overload exists');
SELECT has_function('pgfr_analyze', 'coverage_gaps', ARRAY['timestamptz', 'timestamptz'],
    'coverage_gaps(start, end) exists');
SELECT has_function('pgfr_analyze', 'coverage_gaps', ARRAY['interval'],
    'coverage_gaps(interval) overload exists');

-- -----------------------------------------------------------------------------
-- 2. Fully-populated window: 1.0 ratios, correct expected counts from the
--    60s cadence
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT count(*)::int FROM pgfr_analyze.coverage(
        pgfr_record.epoch() + 600000 * interval '1 second',
        pgfr_record.epoch() + 600600 * interval '1 second')),
    3,
    'coverage() returns one row per collector (sample, snapshot, consumption)');

SELECT is(
    (SELECT format('%s|%s|%s', expected_samples, observed_samples, coverage_ratio)
     FROM pgfr_analyze.coverage(
        pgfr_record.epoch() + 600000 * interval '1 second',
        pgfr_record.epoch() + 600600 * interval '1 second')
     WHERE collector = 'sample'),
    '10|10|1.000',
    'sample collector: 10 expected ticks in 10 minutes, all observed');

SELECT is(
    (SELECT format('%s|%s|%s', expected_samples, observed_samples, coverage_ratio)
     FROM pgfr_analyze.coverage(
        pgfr_record.epoch() + 600000 * interval '1 second',
        pgfr_record.epoch() + 600600 * interval '1 second')
     WHERE collector = 'snapshot'),
    '10|10|1.000',
    'snapshot collector: full coverage on the synthetic window');

SELECT is(
    (SELECT format('%s|%s|%s', expected_samples, observed_samples, coverage_ratio)
     FROM pgfr_analyze.coverage(
        pgfr_record.epoch() + 600000 * interval '1 second',
        pgfr_record.epoch() + 600600 * interval '1 second')
     WHERE collector = 'consumption'),
    '10|10|1.000',
    'consumption collector: full coverage on the synthetic window');

-- -----------------------------------------------------------------------------
-- 3. Gappy window: ratio drops, gap is coalesced and breaker-attributed
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT format('%s|%s|%s', expected_samples, observed_samples, round(coverage_ratio, 3))
     FROM pgfr_analyze.coverage(
        pgfr_record.epoch() + 700200 * interval '1 second',
        pgfr_record.epoch() + 700800 * interval '1 second')
     WHERE collector = 'sample'),
    '10|8|0.800',
    'sample collector: 8 of 10 ticks observed in the gappy window');

SELECT is(
    (SELECT count(*)::int FROM pgfr_analyze.coverage_gaps(
        pgfr_record.epoch() + 700200 * interval '1 second',
        pgfr_record.epoch() + 700800 * interval '1 second')
     WHERE collector = 'sample'),
    1,
    'the two adjacent missing ticks coalesce into one gap');

SELECT is(
    (SELECT format('%s|%s|%s|%s', gap_start, gap_end, duration, attributed_reason)
     FROM pgfr_analyze.coverage_gaps(
        pgfr_record.epoch() + 700200 * interval '1 second',
        pgfr_record.epoch() + 700800 * interval '1 second')
     WHERE collector = 'sample'),
    format('%s|%s|%s|%s',
        pgfr_record.epoch() + 700440 * interval '1 second',
        pgfr_record.epoch() + 700560 * interval '1 second',
        interval '2 minutes', 'circuit_breaker'),
    'the gap spans minutes 4-5 and is attributed to the circuit breaker');

-- -----------------------------------------------------------------------------
-- 4. Retention horizon: the portion of a window older than the oldest
--    retained evidence is attributed retention_horizon
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT format('%s|%s|%s', gap_start, gap_end, attributed_reason)
     FROM pgfr_analyze.coverage_gaps(
        pgfr_record.epoch() + 598200 * interval '1 second',
        pgfr_record.epoch() + 600600 * interval '1 second')
     WHERE collector = 'sample' AND attributed_reason = 'retention_horizon'),
    format('%s|%s|%s',
        pgfr_record.epoch() + 598200 * interval '1 second',
        pgfr_record.epoch() + 600000 * interval '1 second',
        'retention_horizon'),
    'the 30 minutes before the oldest retained ring tick report retention_horizon');

-- -----------------------------------------------------------------------------
-- 5. report() carries the coverage header and qualifies gappy windows
-- -----------------------------------------------------------------------------

SELECT ok(
    pgfr_analyze.report(
        pgfr_record.epoch() + 700200 * interval '1 second',
        pgfr_record.epoch() + 700800 * interval '1 second') ILIKE '%**Coverage:**%',
    'report() output includes the coverage header line');

SELECT ok(
    pgfr_analyze.report(
        pgfr_record.epoch() + 700200 * interval '1 second',
        pgfr_record.epoch() + 700800 * interval '1 second')
        ILIKE '%absence of samples is not absence of activity%',
    'breaker-attributed gaps trigger the MNAR caveat in report()');

SELECT ok(
    pgfr_analyze.report(
        pgfr_record.epoch() + 600000 * interval '1 second',
        pgfr_record.epoch() + 600600 * interval '1 second')
        NOT ILIKE '%absence of samples is not absence of activity%',
    'a fully-covered window is not qualified');

SELECT * FROM finish();
ROLLBACK;
