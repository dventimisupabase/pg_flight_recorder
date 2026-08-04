-- =============================================================================
-- pgfr_analyze pgTAP Tests: capacity_dashboard storage growth (Issue #111)
-- =============================================================================
-- capacity_dashboard.storage_growth_mb_per_day used to regexp-match a
-- "growing N" pattern out of capacity_summary()'s recommendation text, but
-- that wording only ever appeared in current_usage, so the column was NULL
-- always. The fix carries the number as capacity_summary().numeric_value.
--
-- Fixture: two sized snapshots bracketing the 24-hour window whose size
-- delta is exactly 2400 MB. capacity_summary() divides the endpoint delta by
-- (window hours / 24), i.e. by 1.0 for the dashboard's fixed 24-hour window,
-- so the expected growth figure is exactly 2400.0 MB/day. Everything rolls
-- back.
-- =============================================================================

BEGIN;
SELECT plan(6);

DO $$
BEGIN
    -- Oldest sized snapshot in the window: 1000 MB, 23 hours ago.
    INSERT INTO pgfr_record.snapshots (captured_at, pg_version, db_size_bytes)
    VALUES (now() - interval '23 hours', 170000, 1000 * 1024 * 1024::bigint);
    -- Newest sized snapshot: 1000 + 2400 MB, one minute in the future so it
    -- outranks any real tick that fires mid-test.
    INSERT INTO pgfr_record.snapshots (captured_at, pg_version, db_size_bytes)
    VALUES (now() + interval '1 minute', 170000, (1000 + 2400) * 1024 * 1024::bigint);
END $$;

SELECT has_function('pgfr_analyze', 'capacity_summary', ARRAY['interval'],
    'capacity_summary(interval) exists');

SELECT lives_ok(
    $$SELECT metric, current_usage, provisioned_capacity, utilization_pct,
             headroom_pct, status, recommendation, numeric_value
      FROM pgfr_analyze.capacity_summary(interval '24 hours')$$,
    'capacity_summary() returns its columns including numeric_value');

SELECT is(
    (SELECT numeric_value FROM pgfr_analyze.capacity_summary(interval '24 hours')
     WHERE metric = 'storage_growth'),
    2400.0,
    'the storage_growth row carries the growth figure numerically');

-- The original defect: this column was NULL in practice, always.
SELECT is(
    (SELECT storage_growth_mb_per_day FROM pgfr_analyze.capacity_dashboard),
    2400.0,
    'capacity_dashboard.storage_growth_mb_per_day carries the real figure (Issue #111 regression)');

-- OUT variables persist across RETURN NEXT in plpgsql: the figure must not
-- leak into the rows emitted after storage_growth.
SELECT is(
    (SELECT count(*)::int FROM pgfr_analyze.capacity_summary(interval '24 hours')
     WHERE metric <> 'storage_growth' AND numeric_value IS NOT NULL),
    0,
    'numeric_value does not leak into other dimensions'' rows');

SELECT ok(
    (SELECT storage_status IS NOT NULL FROM pgfr_analyze.capacity_dashboard),
    'the dashboard storage status still populates');

SELECT * FROM finish();
ROLLBACK;
