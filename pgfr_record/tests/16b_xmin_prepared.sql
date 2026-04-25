-- =============================================================================
-- pgfr_record pgTAP Tests - Xmin Horizon: Prepared-Transaction Holder (RED)
-- =============================================================================
-- Tests: pgfr_record.xmin_prepared_holders schema + always-collected behavior.
--
-- Why is this in its own file (not 16_xmin_horizon.sql)?
-- Per blueprint XMIN_HORIZON.md §7.1, PREPARE TRANSACTION interacts badly
-- with pgTAP's BEGIN ... ROLLBACK wrapper: a prepared xact survives session
-- and transaction boundaries, so a half-finished test can leave one alive
-- in the cluster and pollute every subsequent run. This file therefore:
--
--   1. Skips when max_prepared_transactions = 0 (common in test clusters).
--   2. Uses dblink to spawn the PREPARE TRANSACTION in a *separate* session,
--      so it really commits to the cluster and is visible cluster-wide.
--   3. Wraps teardown (ROLLBACK PREPARED) in a DO block with an EXCEPTION
--      handler so the prepared xact is unconditionally cleaned up even if
--      an assertion above it fails.
--
-- Phase: RED. The pgfr_record.xmin_prepared_holders table and the
--        prepared-source collection logic do not yet exist on `main`, so
--        every assertion below is *expected* to fail until the production
--        code (XMIN_HORIZON.md §4.3.3 / §5) lands. The file must still
--        load and run without parse errors.
--
-- Spec references:
--   - XMIN_HORIZON.md §4.3.3 — xmin_prepared_holders schema (note:
--     prepared_xmin / prepared_xmin_age, NOT transaction_xid / xmin_age)
--   - XMIN_HORIZON.md §7.1 — "Prepared-always-collected" test pattern
-- =============================================================================

BEGIN;
SELECT plan(6);

-- -----------------------------------------------------------------------------
-- Setup guard: skip cleanly when prepared xacts are disabled in the cluster.
-- pgTAP's skip(reason, how_many) emits N skipped-test markers so the planned
-- count still matches actual output and the run exits successfully.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF current_setting('max_prepared_transactions')::int = 0 THEN
        -- Emit 6 skip markers and short-circuit the rest of the file via a
        -- temp flag. We can't RETURN from a top-level script, so subsequent
        -- blocks gate on this setting.
        PERFORM set_config('pgfr_test.skip_prepared', 'true', false);
    ELSE
        PERFORM set_config('pgfr_test.skip_prepared', 'false', false);
    END IF;
END $$;

-- If skipping, emit 6 skip markers in lieu of real assertions. Under skip
-- mode the planned count is satisfied entirely by these markers; every real
-- assertion below is gated with a WHERE clause so it produces zero rows.
SELECT skip('requires max_prepared_transactions > 0', 6)
WHERE current_setting('pgfr_test.skip_prepared') = 'true';

-- -----------------------------------------------------------------------------
-- The remainder of the file only runs the *real* assertions when not skipped.
-- -----------------------------------------------------------------------------

-- Setup: ensure dblink is available for spawning a separate session.
-- (Required to escape the pgTAP outer BEGIN ... ROLLBACK wrapper, since
--  PREPARE TRANSACTION inside that wrapper would itself be rolled back.)
CREATE EXTENSION IF NOT EXISTS dblink;

-- Setup: a throwaway table for the prepared xact to modify, so the xact
-- has a non-trivial xmin footprint.
DO $$
BEGIN
    IF current_setting('pgfr_test.skip_prepared') = 'false' THEN
        EXECUTE 'CREATE TABLE IF NOT EXISTS pgfr_test_prepared_t (n int)';
        -- Make sure no stale prepared xact from a prior failed run is lying
        -- around; ignore "does not exist" and any other error here.
        BEGIN
            EXECUTE $sql$ROLLBACK PREPARED 'pgfr_test_prepared'$sql$;
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END IF;
END $$;

-- Setup: prove the prepared source uses its OWN floor (xmin_prepared_min_age = 0)
-- and not the shared one. Set the shared floor to int64 max — anything that
-- still gets recorded must have come from the dedicated prepared floor.
INSERT INTO pgfr_record.config (key, value, updated_at)
VALUES ('xmin_holders_min_age', '9223372036854775807', now())
ON CONFLICT (key) DO UPDATE
   SET value = '9223372036854775807', updated_at = now();

-- Spawn a separate session via dblink that opens a transaction, dirties a
-- row, and PREPAREs it. dblink_exec runs each statement in its own implicit
-- transaction, so we must send all three as a single multi-statement string
-- (PREPARE TRANSACTION ends the open transaction explicitly).
DO $$
DECLARE
    -- Project convention (see 07_pathology_generators.sql): bare libpq
    -- connection string with no host — relies on the local UNIX socket /
    -- default listener inside the Docker test container.
    v_connstr text := 'dbname=' || current_database()
                   || ' user=postgres password=postgres';
BEGIN
    IF current_setting('pgfr_test.skip_prepared') = 'true' THEN
        RETURN;
    END IF;

    PERFORM dblink_connect('pgfr_prepared_spawner', v_connstr);
    PERFORM dblink_exec(
        'pgfr_prepared_spawner',
        $sql$
            BEGIN;
            INSERT INTO pgfr_test_prepared_t VALUES (1);
            PREPARE TRANSACTION 'pgfr_test_prepared';
        $sql$
    );
    PERFORM dblink_disconnect('pgfr_prepared_spawner');
END $$;

-- Take a snapshot from the test session. Because xmin_holders_min_age is
-- maxed out, the prepared source is the *only* source that should write
-- a holder row — proving it has its own floor.
DO $$
BEGIN
    IF current_setting('pgfr_test.skip_prepared') = 'false' THEN
        PERFORM pgfr_record.snapshot();
    END IF;
END $$;

-- =============================================================================
-- Assertions (all expected to FAIL on current main — RED phase)
-- =============================================================================

-- 1. Schema: prepared_xmin column exists on xmin_prepared_holders.
SELECT has_column(
    'pgfr_record', 'xmin_prepared_holders', 'prepared_xmin',
    'xmin_prepared_holders should expose prepared_xmin column (XMIN_HORIZON §4.3.3)'
)
WHERE current_setting('pgfr_test.skip_prepared') = 'false';

-- 2. Schema: prepared_xmin_age column exists on xmin_prepared_holders.
SELECT has_column(
    'pgfr_record', 'xmin_prepared_holders', 'prepared_xmin_age',
    'xmin_prepared_holders should expose prepared_xmin_age column (XMIN_HORIZON §4.3.3)'
)
WHERE current_setting('pgfr_test.skip_prepared') = 'false';

-- 3. Regression guard: legacy/draft column transaction_xid must NOT exist.
--    Earlier blueprint drafts (v0.2/v0.3) used transaction_xid; v0.4 renamed
--    to prepared_xmin. This guard catches a regression that resurrects the
--    old name.
SELECT hasnt_column(
    'pgfr_record', 'xmin_prepared_holders', 'transaction_xid',
    'xmin_prepared_holders should NOT have transaction_xid (renamed to prepared_xmin in v0.4)'
)
WHERE current_setting('pgfr_test.skip_prepared') = 'false';

-- 4. Regression guard: legacy/draft column xmin_age must NOT exist.
--    Same rename: was xmin_age; v0.4 standardized on prepared_xmin_age.
SELECT hasnt_column(
    'pgfr_record', 'xmin_prepared_holders', 'xmin_age',
    'xmin_prepared_holders should NOT have xmin_age (renamed to prepared_xmin_age in v0.4)'
)
WHERE current_setting('pgfr_test.skip_prepared') = 'false';

-- 5. Behavior: the prepared xact we spawned was captured in xmin_prepared_holders
--    despite the shared floor being maxed out — proves prepared uses its own
--    xmin_prepared_min_age = 0 floor (XMIN_HORIZON §4.3.3).
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_record.xmin_prepared_holders
        WHERE gid = 'pgfr_test_prepared'
    ),
    'prepared xact captured in xmin_prepared_holders regardless of shared floor'
)
WHERE current_setting('pgfr_test.skip_prepared') = 'false';

-- 6. Behavior: prepared_xmin_age column is populated (non-NULL) for the row
--    we just captured.
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_record.xmin_prepared_holders
        WHERE gid = 'pgfr_test_prepared'
          AND prepared_xmin_age IS NOT NULL
    ),
    'prepared_xmin_age should be populated for the captured prepared xact'
)
WHERE current_setting('pgfr_test.skip_prepared') = 'false';

-- =============================================================================
-- BULLETPROOF TEARDOWN
-- =============================================================================
-- This MUST run even if any assertion above failed (assertion failures in
-- pgTAP do NOT raise SQL errors, so control reaches here unconditionally),
-- AND it must not itself raise an error that aborts the surrounding
-- transaction before finish() can emit the trailer. Hence the DO block with
-- a catch-all EXCEPTION handler around every cleanup statement.
-- =============================================================================
DO $$
BEGIN
    -- ROLLBACK PREPARED — must execute outside any open transaction. We are
    -- inside the pgTAP BEGIN wrapper, so a 2PC ROLLBACK on a *different*
    -- gid actually works because PREPARE TRANSACTION 'pgfr_test_prepared'
    -- was committed by the dblink session (different transaction). The
    -- rollback here targets that already-prepared, session-independent xact.
    BEGIN
        EXECUTE $sql$ROLLBACK PREPARED 'pgfr_test_prepared'$sql$;
    EXCEPTION WHEN OTHERS THEN
        -- Either the test was skipped, or PREPARE TRANSACTION never ran,
        -- or the prepared xact was already cleaned up. Don't propagate.
        NULL;
    END;

    -- Drop the throwaway table.
    BEGIN
        EXECUTE 'DROP TABLE IF EXISTS pgfr_test_prepared_t';
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    -- Best-effort dblink cleanup in case the spawner connection is still open.
    BEGIN
        PERFORM dblink_disconnect('pgfr_prepared_spawner');
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
END $$;

SELECT * FROM finish();
ROLLBACK;
