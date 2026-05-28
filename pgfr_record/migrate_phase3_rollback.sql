-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- migrate_phase3_rollback.sql — undo Phase 3 migration
--
-- Restores legacy heap tables as primary tables by:
--   1. Dropping backwards-compat views
--   2. Renaming _legacy tables back to original names
--   3. Restoring pgfr_cleanup cron (DELETE-based)
--   4. Re-creating dual-write trigger on snapshots
--
-- Run only if migrate_phase3.sql has been applied and you need to roll back.
-- Does NOT restore data written to v2 tables while migration was active.

\set ON_ERROR_STOP 1
set client_min_messages to notice;

begin;

-- Drop backwards-compat views. Archive views (activity_samples_archive,
-- lock_samples_archive, wait_samples_archive) and their INSTEAD OF trigger
-- functions were retired alongside the archive tables themselves.
drop view if exists pgfr_record.snapshots;
drop view if exists pgfr_record.replication_snapshots;
drop view if exists pgfr_record.vacuum_progress_snapshots;
drop view if exists pgfr_record.statement_snapshots;
drop view if exists pgfr_record.table_snapshots;
drop view if exists pgfr_record.index_snapshots;

do $$ begin raise notice 'rollback: views dropped'; end $$;

-- Rename _legacy tables back
do $$
declare
    v_tbl text;
    v_tables text[] := array[
        'snapshots',
        'replication_snapshots',
        'vacuum_progress_snapshots',
        'statement_snapshots',
        'table_snapshots',
        'index_snapshots'
        -- archive_legacy renames retired alongside the archive tables.
    ];
begin
    foreach v_tbl in array v_tables loop
        if exists (
            select 1 from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'pgfr_record'
              and c.relname = v_tbl || '_legacy'
              and c.relkind = 'r'
        ) then
            execute format(
                'alter table pgfr_record.%I rename to %I',
                v_tbl || '_legacy', v_tbl
            );
            raise notice 'rollback: renamed %_legacy → %', v_tbl, v_tbl;
        else
            raise notice 'rollback: %_legacy not found (skipping)', v_tbl;
        end if;
    end loop;
end $$;

-- Restore dual-write trigger on snapshots (now a heap table again)
drop trigger if exists snapshot_v2_dual_write on pgfr_record.snapshots;
create trigger snapshot_v2_dual_write
    after insert on pgfr_record.snapshots
    for each row
    execute function pgfr_record._snapshot_v2_trigger();

-- Restore pgfr_cleanup cron, remove partition GC jobs.
-- Tries both new (#59 underscore) and old (hyphen) names defensively, in case
-- rollback runs against an install on either side of the rename.
do $$
begin
    perform cron.unschedule('pgfr_truncate_partitions')
    where exists (select 1 from cron.job where jobname = 'pgfr_truncate_partitions');

    perform cron.unschedule('pgfr_drop_ancient_partitions')
    where exists (select 1 from cron.job where jobname = 'pgfr_drop_ancient_partitions');

    perform cron.unschedule('pgfr-truncate-partitions')
    where exists (select 1 from cron.job where jobname = 'pgfr-truncate-partitions');

    perform cron.unschedule('pgfr-drop-ancient-partitions')
    where exists (select 1 from cron.job where jobname = 'pgfr-drop-ancient-partitions');

    if not exists (select 1 from cron.job where jobname = 'pgfr_cleanup') then
        perform cron.schedule(
            'pgfr_cleanup',
            '0 3 * * *',
            'select pgfr_record.cleanup()'
        );
    end if;

    raise notice 'rollback: cron restored (pgfr_cleanup re-added, partition GC removed)';
end $$;

do $$ begin raise notice 'rollback: complete. Legacy tables restored as primary tables.'; end $$;

commit;
