-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- milestone 6 acceptance criteria not
-- already covered elsewhere (§10.1)
-- =============================================================================
-- Criteria covered by dedicated infrastructure, not here:
--   1  Install matrix               -- ./test.sh across PG15-18, 3 channels
--   2  Presentation fidelity        -- 04_presentation_views.sql
--   6  Overrun invariant            -- profile_tiers CHECK constraint (13_profiles.sql)
--       + VERIFY №1                 -- pgfr-v2-context-pack.md §5 (empirically confirmed)
--   7  Hash canonicality (VERIFY №2)-- 07_hash_canonicality.sql
--   11 The agent test               -- scripts/agent_test.sh
-- Criteria exercised here: 3 (debounce subset correctness), 4 (ledger
-- correctness: induced timeout and denied), 9 (partition maintenance
-- self-healing).
-- Not automated this session (documented gap, not silently skipped):
--   5  Crash safety (kill -9 mid-run) -- needs a real backend PID and an
--      external SIGKILL; append-only construction makes this low-risk by
--      design (§10.1: "nearly free; assert it anyway"), but a genuine
--      kill -9 test needs shell-level orchestration like agent_test.sh,
--      not a transactional pgTAP file.
--   4  Induced lock_timeout specifically -- needs a second, truly
--      concurrent session holding a lock; same shell-orchestration need
--      as crash safety.
--   8  pg_upgrade drill, 10 cost-model conformance -- heavier operational
--      exercises, deferred.

BEGIN;
SELECT plan(18);

-- ---------------------------------------------------------------------------
-- Debounce correctness (criterion 3): appends happen for exactly the
-- subset of relations whose state actually differs from their most
-- recent capture, and no others, between anchors.
--
-- A real INSERT cannot be used to drive this: PostgreSQL does not surface
-- a table's own cumulative stats (n_tup_ins et al.) to the *same*,
-- still-open transaction that performed the write (confirmed against a
-- live container -- neither pg_stat_force_next_flush() nor
-- stats_fetch_consistency = none changes this; it is not a caching
-- effect, table-level counters simply are not visible pre-commit), and
-- this whole file runs inside one transaction. Instead, a manufactured
-- "changed" marker plays the same role real activity would: it makes
-- debounce_touched's most recent archived row_hash provably differ from
-- its current live one, and leaves debounce_untouched's alone.
-- ---------------------------------------------------------------------------
CREATE TABLE debounce_touched (id int);
CREATE TABLE debounce_untouched (id int);

SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'first medium-tier run (anchor) should capture both new tables');

INSERT INTO pgfr_record.a_pg_stat_all_tables (captured_at, key, key_hash, row_hash, schema_id, payload)
SELECT a.captured_at + interval '1 millisecond', a.key, a.key_hash, 0::bigint, a.schema_id, a.payload
FROM pgfr_record.a_pg_stat_all_tables a, pgfr_record.src_catalog_identity c
WHERE (a.key->>'relid')::oid = c.oid AND c.relname = 'debounce_touched'
ORDER BY a.captured_at DESC LIMIT 1;

SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'second medium-tier run should only append for the relation whose most recent row_hash differs from its live state');

SELECT is(
    (SELECT count(*)::int FROM pgfr_record.a_pg_stat_all_tables a, pgfr_record.src_catalog_identity c
     WHERE (a.key->>'relid')::oid = c.oid AND c.relname = 'debounce_touched'),
    3,
    'the touched relation should have 3 archive rows: the anchor, the manufactured marker, and the real append the marker provoked'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.a_pg_stat_all_tables a, pgfr_record.src_catalog_identity c
     WHERE (a.key->>'relid')::oid = c.oid AND c.relname = 'debounce_untouched'),
    1,
    'the untouched relation should have exactly 1 archive row (only the anchor -- debounce correctly skipped the second tick)'
);

-- ---------------------------------------------------------------------------
-- Ledger correctness (criterion 4): induced statement_timeout, via the
-- real mechanism (§5's arming gotcha, corrected during this milestone):
-- a SET LOCAL statement_timeout from *inside* run_tier()'s own top-level
-- call cannot preemptively cancel anything -- only a SET issued as its
-- own *preceding* top-level statement can, exactly as apply_profile()
-- now dispatches every tier job ("SET statement_timeout = ...; SELECT
-- run_tier(...)", two statements). This test reproduces that same
-- two-statement shape directly, rather than passing a timeout parameter
-- to run_tier() (section_timeout was removed; see 08_collector.sql).
--
-- This is a genuine wall-clock race (a real pg_sleep against a real
-- timeout), so unlike every other test in this suite it carries a small
-- irreducible flake risk under sufficiently extreme host contention:
-- statement_timeout fires via OS signal delivery to the backend, and a
-- sufficiently CPU-starved host can delay that delivery arbitrarily
-- long, regardless of the margin chosen. Observed reliable across dozens
-- of runs under this project's own test.sh (up to 4 majors in
-- parallel); the EXCEPTION WHEN query_canceled branch it exercises is
-- the same per-target isolation mechanism the adjacent 'error' and
-- 'denied' tests already prove correct via non-timing-based triggers,
-- so this test's marginal value is specifically "the timeout branch
-- fires on a real timeout", not the isolation guarantee itself.
-- ---------------------------------------------------------------------------
UPDATE pgfr_record.capture_plan
SET capture_select_sql = 'SELECT NULL::jsonb AS key, NULL::bigint AS key_hash, 1::bigint AS row_hash, jsonb_build_array(pg_sleep(3)::text) AS payload'
WHERE source_view = 'pg_catalog.pg_stat_wal_receiver';

SET LOCAL statement_timeout = '200ms';
SELECT lives_ok(
    $$SELECT pgfr_record.run_tier('fast', interval '100 ms', interval '10 seconds')$$,
    'run_tier() should complete even though a caller-armed statement_timeout cancels one target''s capture'
);
SET LOCAL statement_timeout = DEFAULT;

SELECT is(
    (SELECT outcome FROM pgfr_record.ledger_captures lc JOIN pgfr_record.ledger_runs lr ON lr.run_id = lc.run_id
     WHERE lr.tier = 'fast' AND lc.source_view = 'pg_catalog.pg_stat_wal_receiver' ORDER BY lr.finished_at DESC LIMIT 1),
    'timeout',
    'a capture cancelled by the caller-armed statement_timeout should be recorded as outcome = timeout, not fail the tier'
);
SELECT is(
    (SELECT outcome FROM pgfr_record.ledger_captures lc JOIN pgfr_record.ledger_runs lr ON lr.run_id = lc.run_id
     WHERE lr.tier = 'fast' AND lc.source_view = 'pg_catalog.pg_stat_archiver' ORDER BY lr.finished_at DESC LIMIT 1),
    'ok',
    'a sibling target in the same tier should still succeed despite another target timing out'
);

SELECT pgfr_record.generate_capture_plan();  -- restore the manifest-driven capture_select_sql

-- ---------------------------------------------------------------------------
-- job_timeout's cooperative deadline check (the other half of §5's
-- arming-gotcha fix): once a slow target has consumed the tier's whole
-- job_timeout budget, run_tier() must stop *starting* further targets --
-- it cannot interrupt the one already in flight (that needs the
-- caller-armed statement_timeout above), but every later target in
-- plan_order should be left with no ledger_captures row at all for this
-- run, not a failure.
-- ---------------------------------------------------------------------------
SELECT source_view FROM pgfr_record.capture_plan WHERE cadence_tier = 'fast' ORDER BY plan_order LIMIT 1 \gset first_
SELECT source_view FROM pgfr_record.capture_plan WHERE cadence_tier = 'fast' ORDER BY plan_order DESC LIMIT 1 \gset last_

UPDATE pgfr_record.capture_plan
SET capture_select_sql = 'SELECT NULL::jsonb AS key, NULL::bigint AS key_hash, 1::bigint AS row_hash, jsonb_build_array(pg_sleep(2)::text) AS payload'
WHERE cadence_tier = 'fast' AND source_view = :'first_source_view';

SELECT lives_ok(
    $$SELECT pgfr_record.run_tier('fast', interval '100 ms', interval '500 ms')$$,
    'run_tier() should complete even though its job_timeout budget is exhausted partway through the tier'
);
SELECT max(lr.run_id) AS run_id FROM pgfr_record.ledger_runs lr WHERE lr.tier = 'fast' \gset budget_

SELECT is(
    (SELECT outcome FROM pgfr_record.ledger_captures WHERE run_id = :budget_run_id AND source_view = :'first_source_view'),
    'ok',
    'the slow first-in-plan-order target should still complete and be recorded, having started before the budget was spent'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.ledger_captures WHERE run_id = :budget_run_id AND source_view = :'last_source_view'),
    0,
    'the last-in-plan-order target should have no ledger_captures row for this run: job_timeout''s budget was spent before its turn'
);

SELECT pgfr_record.generate_capture_plan();  -- restore the manifest-driven capture_select_sql

-- ---------------------------------------------------------------------------
-- Ledger correctness (criterion 4): induced insufficient_privilege. A
-- restricted role granted full access to pgfr_record's own objects is
-- still denied pg_hba_file_rules by Postgres' own privilege system,
-- independent of anything pgfr_record grants.
-- ---------------------------------------------------------------------------
CREATE ROLE restricted_test_role LOGIN;
GRANT USAGE ON SCHEMA pgfr_record TO restricted_test_role;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA pgfr_record TO restricted_test_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA pgfr_record TO restricted_test_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgfr_record TO restricted_test_role;

SET ROLE restricted_test_role;
SELECT lives_ok(
    $$SELECT pgfr_record.run_tier('on_change', interval '100 ms', interval '4 minutes')$$,
    'run_tier() should complete even though the calling role lacks privilege on one target'
);
RESET ROLE;

SELECT is(
    (SELECT outcome FROM pgfr_record.ledger_captures lc JOIN pgfr_record.ledger_runs lr ON lr.run_id = lc.run_id
     WHERE lr.tier = 'on_change' AND lc.source_view = 'pg_catalog.pg_hba_file_rules' ORDER BY lr.finished_at DESC LIMIT 1),
    'denied',
    'a target the calling role cannot read should be recorded as outcome = denied'
);
-- pg_roles, not pg_settings, as the "sibling still succeeds" check: a
-- handful of rows in a test database captures near-instantly regardless
-- of system load, keeping this assertion about isolation, not timing.
SELECT is(
    (SELECT outcome FROM pgfr_record.ledger_captures lc JOIN pgfr_record.ledger_runs lr ON lr.run_id = lc.run_id
     WHERE lr.tier = 'on_change' AND lc.source_view = 'pg_catalog.pg_roles' ORDER BY lr.finished_at DESC LIMIT 1),
    'ok',
    'a sibling target readable by every role should still succeed in the same run'
);

-- ---------------------------------------------------------------------------
-- Partition maintenance self-healing (criterion 9): a target with no
-- partition covering the current capture time produces a ledger error
-- (never an uncaught exception or a failed tier), and self-heals once
-- maintain_partitions() runs again.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_child text;
BEGIN
    FOR v_child IN
        SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_class p ON p.oid = i.inhparent
        WHERE p.relname = 'a_pg_stat_wal'
    LOOP
        EXECUTE format('ALTER TABLE pgfr_record.a_pg_stat_wal DETACH PARTITION pgfr_record.%I', v_child);
        EXECUTE format('DROP TABLE pgfr_record.%I', v_child);
    END LOOP;
END $$;

SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'a run_tier() call with zero partitions available for one target should not fail the tier');
SELECT is(
    (SELECT outcome FROM pgfr_record.ledger_captures lc JOIN pgfr_record.ledger_runs lr ON lr.run_id = lc.run_id
     WHERE lr.tier = 'fast' AND lc.source_view = 'pg_catalog.pg_stat_wal' ORDER BY lr.finished_at DESC LIMIT 1),
    'error',
    'a capture with no partition to land in should be recorded as outcome = error (§4.2''s insert-time backstop), not raise uncaught'
);

SELECT lives_ok($$SELECT pgfr_record.maintain_partitions()$$, 'maintain_partitions() should self-heal by recreating the missing partitions');
SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'a subsequent run_tier() call should succeed once partitions are restored');
SELECT is(
    (SELECT outcome FROM pgfr_record.ledger_captures lc JOIN pgfr_record.ledger_runs lr ON lr.run_id = lc.run_id
     WHERE lr.tier = 'fast' AND lc.source_view = 'pg_catalog.pg_stat_wal' ORDER BY lr.finished_at DESC LIMIT 1),
    'ok',
    'after maintain_partitions() self-heals, the next capture should succeed without any further intervention'
);

SELECT * FROM finish();
ROLLBACK;
