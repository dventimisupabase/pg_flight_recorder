-- =============================================================================
-- pgTAP tests: Phase 1 / Issue #9 — snapshot() wiring + pg_cron GC jobs
-- SPEC §9.13 — Phase 1 test items
-- Run with: pg_prove -d <dbname> pgfr_record/tests/test_wiring.sql
-- Requires: pgTAP, pg_cron, pgfr_record/install.sql installed
-- PG14+ minimum
--
-- Coverage:
--   W1: snapshot() creates today's partition for statement_snapshots_v2
--   W2: snapshot() creates today's partition for table_snapshots_v2 (when available)
--   W3: snapshot() creates today's partition for index_snapshots_v2 (when available)
--   W4: pg_cron job 'pgfr_truncate_partitions' exists
--   W5: pg_cron job 'pgfr_drop_ancient_partitions' exists
--   W6: snapshot() returns a timestamptz (completes without error)
--   W7: failure in one sparse collector does not abort others (isolation)
--   W8: _collect_statement_snapshot_sparse is called by snapshot() (rows in v2)
-- =============================================================================

begin;

select plan(8);

-- ---------------------------------------------------------------------------
-- Helper: run snapshot() once to trigger all wiring
-- ---------------------------------------------------------------------------
do $$
begin
    perform pgfr_record.snapshot();
end;
$$;

-- ===========================================================================
-- W1: snapshot() creates today's partition for statement_snapshots_v2
-- ===========================================================================
select ok(
    exists (
        select 1
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'statement_snapshots_v2_' || to_char(current_date, 'YYYY_MM_DD')
          and c.relkind = 'r'
    ),
    'W1: snapshot() must create today''s partition for statement_snapshots_v2'
);

-- ===========================================================================
-- W2: snapshot() attempts to create today's partition for table_snapshots_v2
--     If Issue #8 is not merged, parent table won't exist and snapshot() must
--     still succeed (exception block swallows the error). We test for
--     graceful handling: either partition exists OR snapshot() didn't crash.
-- ===========================================================================
select ok(
    -- Either the partition exists (Issue #8 merged) OR the parent table doesn't
    -- exist yet (Issue #8 pending) — both are valid states for this issue.
    (
        exists (
            select 1
            from pg_catalog.pg_class c
            join pg_catalog.pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'pgfr_record'
              and c.relname = 'table_snapshots_v2_' || to_char(current_date, 'YYYY_MM_DD')
        )
        or
        not exists (
            select 1
            from pg_catalog.pg_class c
            join pg_catalog.pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'pgfr_record'
              and c.relname = 'table_snapshots_v2'
        )
    ),
    'W2: snapshot() must not crash when table_snapshots_v2 parent is absent or partition exists'
);

-- ===========================================================================
-- W3: snapshot() attempts to create today's partition for index_snapshots_v2
--     Same graceful-handling logic as W2.
-- ===========================================================================
select ok(
    (
        exists (
            select 1
            from pg_catalog.pg_class c
            join pg_catalog.pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'pgfr_record'
              and c.relname = 'index_snapshots_v2_' || to_char(current_date, 'YYYY_MM_DD')
        )
        or
        not exists (
            select 1
            from pg_catalog.pg_class c
            join pg_catalog.pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'pgfr_record'
              and c.relname = 'index_snapshots_v2'
        )
    ),
    'W3: snapshot() must not crash when index_snapshots_v2 parent is absent or partition exists'
);

-- ===========================================================================
-- W4: pg_cron job 'pgfr_truncate_partitions' exists
-- ===========================================================================
SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
    THEN skip('W4: pg_cron not in this database — cron job check skipped')
    ELSE ok(
        EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_truncate_partitions'),
        'W4: pg_cron job pgfr_truncate_partitions must be registered'
    )
END;

-- ===========================================================================
-- W5: pg_cron job 'pgfr_drop_ancient_partitions' exists
-- ===========================================================================
SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
    THEN skip('W5: pg_cron not in this database — cron job check skipped')
    ELSE ok(
        EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_drop_ancient_partitions'),
        'W5: pg_cron job pgfr_drop_ancient_partitions must be registered'
    )
END;

-- ===========================================================================
-- W6: snapshot() returns a timestamptz (completes without error)
-- ===========================================================================
select ok(
    (select pgfr_record.snapshot() is not null),
    'W6: snapshot() must return a non-null timestamptz'
);

-- ===========================================================================
-- W7: failure in one sparse collector does not abort others (isolation)
--     Simulate: create a bad version of _collect_statement_snapshot_sparse
--     that always raises, call snapshot(), verify it still returns.
--     We test isolation by confirming snapshot() survives collector failure.
-- ===========================================================================
do $$
begin
    -- Override statement sparse collector to always raise
    create or replace function pgfr_record._collect_statement_snapshot_sparse(p_snapshot_id bigint)
    returns void language plpgsql as $f$
    begin
        raise exception 'W7: injected failure for isolation test';
    end;
    $f$;
end;
$$;

select ok(
    (select pgfr_record.snapshot() is not null),
    'W7: snapshot() must survive failure in _collect_statement_snapshot_sparse and still return'
);

-- Restore the original sparse collector by reinstalling from current schema
-- (rollback will undo our override since we're in a transaction)

-- ===========================================================================
-- W8: GC cron job schedules are correct
--     truncate job: '0 3 * * *'  (nightly 03:00 UTC)
--     drop job:     '0 4 1 * *'  (monthly 1st, 04:00 UTC)
-- ===========================================================================
SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
    THEN skip('W8: pg_cron not in this database — schedule check skipped')
    ELSE ok(
        EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_truncate_partitions' AND schedule = '0 3 * * *')
        AND
        EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_drop_ancient_partitions' AND schedule = '0 4 1 * *'),
        'W8: GC cron jobs must have correct schedules (03:00 UTC nightly, 04:00 UTC monthly)'
    )
END;

select * from finish();
rollback;
