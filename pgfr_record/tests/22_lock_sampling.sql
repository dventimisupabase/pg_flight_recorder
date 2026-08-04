-- 22_lock_sampling.sql
--
-- Tests for the lock-sampling lane of sample_ring(): blocked/blocking pairs
-- captured into pgfr_record.lock_samples.
--
-- Covers:
--   1. Schema sanity (lock_samples exists)
--   2. No contention -> no advisory lock rows written
--   3-7. Live contention (two dblink sessions contending on an advisory
--        lock) -> pair captured with decodable lock_type, sane duration,
--        and visible through recent_locks
--   8. enable_locks = false disables the lane
--   9. skip_locks_threshold exceeded skips the lane
--   10. restored config -> lane captures again
--   11. _flush_ring_slot_to_rollups() rolls captured pairs into
--       lock_rollups_archive_v2
--
-- Isolation notes:
--   - REPEATABLE READ pins our snapshot so rows committed mid-test by the
--     live pgfr_sample_ring cron job can't perturb count assertions.
--     pg_locks always reflects live state, but pg_stat_activity is cached
--     per transaction, so pg_stat_clear_snapshot() must run before every
--     sample_ring() call that needs to observe activity changed mid-test.
--   - Assertions count only advisory-lock rows: real background sessions
--     in the test container never contend on advisory locks, so the
--     counters are isolated from any concurrent genuine lock contention.

BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

SELECT plan(11);

CREATE EXTENSION IF NOT EXISTS dblink;

-- Baseline/state scratchpad
CREATE TEMP TABLE _lock_test_state (key text PRIMARY KEY, val bigint);

-- Count of advisory-lock sample rows (the only lock type this test creates)
CREATE TEMP VIEW _advisory_rows AS
    SELECT count(*) AS n
    FROM pgfr_record.lock_samples ls
    JOIN pgfr_record.lock_type_map ltm
      ON ltm.id = ls.lock_type AND ltm.lock_type = 'advisory';

-- 1. Schema sanity
SELECT has_table('pgfr_record'::name, 'lock_samples'::name,
    'lock_samples table exists');

-- 2. No contention -> sample_ring() writes no advisory lock rows
INSERT INTO _lock_test_state VALUES ('c0', (SELECT n FROM _advisory_rows));
SELECT pgfr_record.sample_ring();
SELECT is(
    (SELECT n FROM _advisory_rows) - (SELECT val FROM _lock_test_state WHERE key = 'c0'),
    0::bigint,
    'no contention: sample_ring() writes no advisory lock rows');

-- ---------------------------------------------------------------------------
-- Create real lock contention: session A holds pg_advisory_lock(424242),
-- session B blocks trying to acquire the same key.
-- ---------------------------------------------------------------------------
SELECT dblink_connect('pgfr_test_blocker',
    format('dbname=%s user=postgres', current_database()));
SELECT dblink_connect('pgfr_test_blocked',
    format('dbname=%s user=postgres', current_database()));

INSERT INTO _lock_test_state VALUES ('blocker_pid',
    (SELECT t.pid FROM dblink('pgfr_test_blocker',
        'SELECT pg_backend_pid()') AS t(pid int)));

-- Blocker acquires the lock synchronously (held until disconnect)
SELECT * FROM dblink('pgfr_test_blocker',
    'SELECT pg_advisory_lock(424242)') AS t(x text);

-- Blocked session tries the same key asynchronously and stalls
SELECT dblink_send_query('pgfr_test_blocked', 'SELECT pg_advisory_lock(424242)');

-- Wait (up to 10s) for the blocked session to show up waiting in pg_locks
DO $$
DECLARE
    i int := 0;
BEGIN
    WHILE i < 100 LOOP
        EXIT WHEN EXISTS (
            SELECT 1 FROM pg_locks
            WHERE locktype = 'advisory' AND objid = 424242 AND NOT granted);
        PERFORM pg_sleep(0.1);
        i := i + 1;
    END LOOP;
    IF i >= 100 THEN
        RAISE EXCEPTION 'blocked session never started waiting on the advisory lock';
    END IF;
END $$;

INSERT INTO _lock_test_state VALUES ('blocked_pid',
    (SELECT pid FROM pg_locks
     WHERE locktype = 'advisory' AND objid = 424242 AND NOT granted));

-- 3. Contention captured (clear the cached activity snapshot first: it was
--    pinned by the sample_ring() call above, before the contention existed)
SELECT pg_stat_clear_snapshot();
INSERT INTO _lock_test_state VALUES ('c1', (SELECT n FROM _advisory_rows));
SELECT pgfr_record.sample_ring();
SELECT cmp_ok(
    (SELECT n FROM _advisory_rows) - (SELECT val FROM _lock_test_state WHERE key = 'c1'),
    '>=', 1::bigint,
    'live contention: sample_ring() writes at least one advisory lock row');

-- 4/5. The captured pair is ours: correct blocked and blocking pids
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_record.lock_samples ls
        JOIN pgfr_record.lock_type_map ltm ON ltm.id = ls.lock_type
        WHERE ltm.lock_type = 'advisory'
          AND ls.blocked_pid  = (SELECT val FROM _lock_test_state WHERE key = 'blocked_pid')
          AND ls.blocking_pid = (SELECT val FROM _lock_test_state WHERE key = 'blocker_pid')),
    'captured pair matches the known blocked/blocking pids');
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.lock_samples
        WHERE blocked_pid = blocking_pid),
    'no self-blocking rows recorded');

-- 6. Duration is present and sane
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_record.lock_samples ls
        WHERE ls.blocked_pid = (SELECT val FROM _lock_test_state WHERE key = 'blocked_pid')
          AND ls.blocked_duration_s IS NOT NULL
          AND ls.blocked_duration_s >= 0),
    'blocked_duration_s is non-null and non-negative');

-- 7. The pair surfaces through the recent_locks reader view
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_record.recent_locks
        WHERE blocked_pid  = (SELECT val FROM _lock_test_state WHERE key = 'blocked_pid')
          AND blocking_pid = (SELECT val FROM _lock_test_state WHERE key = 'blocker_pid')
          AND lock_type = 'advisory'),
    'recent_locks view exposes the captured pair with decoded lock_type');

-- 8. enable_locks = false disables the lane (contention still live)
INSERT INTO pgfr_record.config (key, value) VALUES ('enable_locks', 'false')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
SELECT pg_stat_clear_snapshot();
INSERT INTO _lock_test_state VALUES ('c2', (SELECT n FROM _advisory_rows));
SELECT pgfr_record.sample_ring();
SELECT is(
    (SELECT n FROM _advisory_rows) - (SELECT val FROM _lock_test_state WHERE key = 'c2'),
    0::bigint,
    'enable_locks = false: lock lane writes nothing under live contention');

-- 9. skip_locks_threshold exceeded skips the lane (1 waiter > threshold 0)
INSERT INTO pgfr_record.config (key, value) VALUES ('enable_locks', 'true')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO pgfr_record.config (key, value) VALUES ('skip_locks_threshold', '0')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
SELECT pg_stat_clear_snapshot();
INSERT INTO _lock_test_state VALUES ('c3', (SELECT n FROM _advisory_rows));
SELECT pgfr_record.sample_ring();
SELECT is(
    (SELECT n FROM _advisory_rows) - (SELECT val FROM _lock_test_state WHERE key = 'c3'),
    0::bigint,
    'skip_locks_threshold exceeded: lock lane skipped under a lock storm');

-- 10. Restored config -> lane captures again
INSERT INTO pgfr_record.config (key, value) VALUES ('skip_locks_threshold', '50')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
SELECT pg_stat_clear_snapshot();
INSERT INTO _lock_test_state VALUES ('c4', (SELECT n FROM _advisory_rows));
SELECT pgfr_record.sample_ring();
SELECT cmp_ok(
    (SELECT n FROM _advisory_rows) - (SELECT val FROM _lock_test_state WHERE key = 'c4'),
    '>=', 1::bigint,
    'restored config: lock lane captures again');

-- 11. Flush rolls the captured pairs into lock_rollups_archive_v2
SELECT pgfr_record._flush_ring_slot_to_rollups(pgfr_record.ring_current_slot());
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_record.lock_rollups_archive_v2
        WHERE lock_type = 'advisory' AND occurrence_count >= 1),
    'flush: advisory pairs rolled up into lock_rollups_archive_v2');

-- Cleanup: cancel the stuck acquire, then drop both connections
SELECT dblink_cancel_query('pgfr_test_blocked');
SELECT dblink_disconnect('pgfr_test_blocked');
SELECT dblink_disconnect('pgfr_test_blocker');

SELECT * FROM finish();
ROLLBACK;
