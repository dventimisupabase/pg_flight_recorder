-- =============================================================================
-- pgfr_record pgTAP Tests — Phase 3 Migration: INSTEAD OF INSERT Triggers
-- =============================================================================
-- Tests the INSTEAD OF INSERT triggers created by migrate_phase3.sql.
-- Requires: install.sql applied FIRST, then migrate_phase3.sql applied SECOND.
-- Run via: psql -f tests/test_migration_triggers.sql
--
-- NOTE: This test applies the migration (migrate_phase3.sql) and rolls it back
-- using migrate_phase3_rollback.sql at the end so the DB is restored for
-- subsequent tests in the same test run.
-- =============================================================================

-- Seed snapshots_v2 (needed for migration pre-flight)
select pgfr_record.snapshot();
select pgfr_record.snapshot();

-- Apply phase 3 migration
\i /tmp/migrate_phase3.sql

begin;
select plan(9);

-- T1: snapshots view is now a UNION ALL view (not a base table)
select ok(
    (select relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'pgfr_record' and c.relname = 'snapshots') = 'v',
    'T1: snapshots is a view after migration'
);

-- T2: INSTEAD OF INSERT trigger exists on snapshots view
select ok(
    exists(
        select 1 from pg_trigger t
        join pg_class c on c.oid = t.tgrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record' and c.relname = 'snapshots'
          and t.tgname = 'snapshots_view_insert'
    ),
    'T2: snapshots_view_insert trigger exists on snapshots view'
);

-- T3: snapshot() works without errors after migration
do $$
begin
    perform pgfr_record.snapshot();
end $$;
select ok(true, 'T3: snapshot() executes without error post-migration');

-- T4: snapshot() routes to snapshots_v2 (row count increases)
select ok(
    (select count(*) from pgfr_record.snapshots_v2) >= 3,
    'T4: snapshots_v2 has >= 3 rows (2 pre-migration + >= 1 post-migration)'
);

-- T5: snapshots view returns UNION ALL of v2 + legacy
select ok(
    (select count(*) from pgfr_record.snapshots)
    = (select count(*) from pgfr_record.snapshots_v2)
      + (select count(*) from pgfr_record.snapshots_legacy),
    'T5: snapshots view count = snapshots_v2 + snapshots_legacy'
);

-- T6: bare INSERT (only captured_at, no pg_version) works via trigger default
do $$
declare v_id integer;
begin
    insert into pgfr_record.snapshots (captured_at)
    values (now())
    returning id into v_id;
    if v_id is null then
        raise exception 'RETURNING id returned null';
    end if;
end $$;
select ok(true, 'T6: bare INSERT INTO snapshots (captured_at) works, RETURNING id non-null');

-- T7: activity_samples_archive INSTEAD OF INSERT routes to _v2
do $$
begin
    insert into pgfr_record.activity_samples_archive (captured_at, pid, state)
    values (now(), 12345, 'active');
end $$;
select ok(
    exists (
        select 1 from pgfr_record.activity_samples_archive_v2
        where pid = 12345 and state = 'active'
    ),
    'T7: INSERT INTO activity_samples_archive routes to activity_samples_archive_v2'
);

-- T8: lock_samples_archive INSTEAD OF INSERT routes to _v2
do $$
begin
    insert into pgfr_record.lock_samples_archive (captured_at, blocked_pid, blocking_pid)
    values (now(), 22222, 33333);
end $$;
select ok(
    exists (
        select 1 from pgfr_record.lock_samples_archive_v2
        where blocked_pid = 22222 and blocking_pid = 33333
    ),
    'T8: INSERT INTO lock_samples_archive routes to lock_samples_archive_v2'
);

-- T9: wait_samples_archive INSTEAD OF INSERT routes to _v2
do $$
begin
    insert into pgfr_record.wait_samples_archive (captured_at, wait_event_type, wait_event, count)
    values (now(), 'Lock', 'relation', 7);
end $$;
select ok(
    exists (
        select 1 from pgfr_record.wait_samples_archive_v2
        where wait_event_type = 'Lock' and wait_event = 'relation' and count = 7
    ),
    'T9: INSERT INTO wait_samples_archive routes to wait_samples_archive_v2'
);

select * from finish();
rollback;

-- Restore pre-migration state so subsequent tests in the same run are not affected.
-- migrate_phase3_rollback.sql drops the views and renames _legacy tables back.
-- After rollback, re-register partition GC cron jobs that install.sql added
-- so test_wiring.sql still finds them (rollback removes them as part of
-- restoring the pre-migration cron state).
\i /tmp/migrate_phase3_rollback.sql

do $$
begin
    if not exists (select 1 from cron.job where jobname = 'pgfr_truncate_partitions') then
        perform cron.schedule('pgfr_truncate_partitions', '0 3 * * *',
            'select pgfr_record.truncate_old_partitions()');
    end if;
    if not exists (select 1 from cron.job where jobname = 'pgfr_drop_ancient_partitions') then
        perform cron.schedule('pgfr_drop_ancient_partitions', '0 4 1 * *',
            'select pgfr_record.drop_ancient_partitions()');
    end if;
end $$;
