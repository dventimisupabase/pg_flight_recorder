-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Phase 1 Migration: old tables → v2 partitioned tables
-- Safe to run on live system. Idempotent.
-- Run AFTER installing the new pgfr_record/install.sql (which adds v2 tables).
--
-- Usage:
--   SELECT pgfr_record.migrate_to_v2();
--
-- What it does:
--   1. Verifies v2 tables exist (raises ERROR if install.sql has not been run)
--   2. Renames old tables to _legacy suffix (idempotent — skips if already renamed)
--   3. Creates backwards-compat views so existing SELECT queries continue to work
--   4. Returns a text summary of actions taken
--
-- Rollback:
--   To undo: rename _legacy tables back and drop the views.
--   Old data is preserved in the _legacy tables — nothing is deleted.

-- ============================================================================
-- migrate_to_v2() — main migration entry point
-- ============================================================================
create or replace function pgfr_record.migrate_to_v2()
returns text
language plpgsql
as $$
declare
    v_actions      text[] := '{}';
    v_summary      text;
    v_v2_missing   text[] := '{}';
    v_table_name   text;
    v_v2_tables    text[] := array[
        'statement_snapshots_v2',
        'table_snapshots_v2',
        'index_snapshots_v2'
    ];
    v_old_tables   text[] := array[
        'statement_snapshots',
        'table_snapshots',
        'index_snapshots'
    ];
    v_any_legacy   boolean := false;
begin
    -- ----------------------------------------------------------------
    -- Step 1: verify v2 tables exist.
    -- If any are missing, raise an error telling the operator what to do.
    -- ----------------------------------------------------------------
    foreach v_table_name in array v_v2_tables loop
        if not exists (
            select 1
            from pg_catalog.pg_class c
            join pg_catalog.pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'pgfr_record'
              and c.relname = v_table_name
              and c.relkind in ('r', 'p')  -- regular table or partitioned table
        ) then
            v_v2_missing := v_v2_missing || v_table_name;
        end if;
    end loop;

    if array_length(v_v2_missing, 1) > 0 then
        raise exception
            e'migrate_to_v2() aborted: v2 tables are missing: %\n'
            'Run the new pgfr_record/install.sql first, then retry migration.\n'
            'Example: \\i pgfr_record/install.sql',
            array_to_string(v_v2_missing, ', ');
    end if;

    -- ----------------------------------------------------------------
    -- Step 2: rename old tables to _legacy (idempotent).
    -- Only rename tables that still have their original names.
    -- ----------------------------------------------------------------
    foreach v_table_name in array v_old_tables loop
        declare
            v_original_exists boolean;
            v_legacy_exists   boolean;
            v_legacy_name     text := v_table_name || '_legacy';
        begin
            v_original_exists := exists (
                select 1
                from pg_catalog.pg_class c
                join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                where n.nspname = 'pgfr_record'
                  and c.relname = v_table_name
                  and c.relkind = 'r'  -- plain heap table (not partitioned)
            );

            v_legacy_exists := exists (
                select 1
                from pg_catalog.pg_class c
                join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                where n.nspname = 'pgfr_record'
                  and c.relname = v_legacy_name
                  and c.relkind = 'r'
            );

            if v_original_exists and not v_legacy_exists then
                -- rename old table to _legacy
                -- lock_timeout guards against long-running queries holding AccessShareLock
                -- and causing a cascading lock pile-up on a live system
                set local lock_timeout = '2s';
                execute format(
                    'alter table pgfr_record.%I rename to %I',
                    v_table_name,
                    v_legacy_name
                );
                raise notice 'migrate_to_v2: renamed pgfr_record.% → pgfr_record.%',
                    v_table_name, v_legacy_name;
                v_actions := v_actions || format('renamed %s → %s', v_table_name, v_legacy_name);

            elsif v_legacy_exists and not v_original_exists then
                raise notice 'migrate_to_v2: pgfr_record.% already renamed to pgfr_record.% — skipping',
                    v_table_name, v_legacy_name;
                v_any_legacy := true;

            elsif v_original_exists and v_legacy_exists then
                -- both exist — something unexpected; report it
                raise notice 'migrate_to_v2: both pgfr_record.% and pgfr_record.% exist — manual intervention required',
                    v_table_name, v_legacy_name;
                v_actions := v_actions || format(
                    'WARNING: both %s and %s exist — skipped',
                    v_table_name, v_legacy_name
                );

            else
                -- neither original nor legacy exists — nothing to migrate for this table
                raise notice 'migrate_to_v2: pgfr_record.% not found — skipping',
                    v_table_name;
            end if;
        end;
    end loop;

    -- ----------------------------------------------------------------
    -- Step 3: create backwards-compat views (one per renamed table).
    -- The view replaces the old table name so existing SELECT queries
    -- continue to work without modification.
    -- ----------------------------------------------------------------
    foreach v_table_name in array v_old_tables loop
        declare
            v_legacy_name text := v_table_name || '_legacy';
            v_view_exists boolean;
        begin
            -- only create the view if the _legacy table exists
            if not exists (
                select 1
                from pg_catalog.pg_class c
                join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                where n.nspname = 'pgfr_record'
                  and c.relname = v_legacy_name
                  and c.relkind = 'r'
            ) then
                continue;
            end if;

            -- create or replace the backwards-compat view
            execute format(
                'create or replace view pgfr_record.%I as select * from pgfr_record.%I',
                v_table_name,
                v_legacy_name
            );
            execute format(
                $c$comment on view pgfr_record.%I is
                'Backwards-compatibility view: redirects reads from the old %s table '
                'to %s_legacy after Phase 1 migration. '
                'For new queries, use the v2 partitioned table instead.'$c$,
                v_table_name, v_table_name, v_table_name
            );
            raise notice 'migrate_to_v2: created/updated backwards-compat view pgfr_record.%',
                v_table_name;
            v_actions := v_actions || format('created view %s → %s', v_table_name, v_legacy_name);
        end;
    end loop;

    -- ----------------------------------------------------------------
    -- Step 4: return summary
    -- ----------------------------------------------------------------
    if v_any_legacy and array_length(v_actions, 1) is null then
        v_summary := 'migrate_to_v2: already migrated — legacy tables exist, no changes made';
    elsif not v_any_legacy and array_length(v_actions, 1) is null then
        v_summary := 'migrate_to_v2: nothing to migrate — original tables not found (fresh install?)';
    else
        v_summary := 'migrate_to_v2: ' || array_to_string(v_actions, '; ');
    end if;

    raise notice '%', v_summary;
    return v_summary;
end;
$$;

comment on function pgfr_record.migrate_to_v2() is
'Phase 1 migration: renames old plain tables to _legacy suffix and creates backwards-compat views. '
'Idempotent — safe to call multiple times. '
'Requires v2 tables (statement_snapshots_v2, table_snapshots_v2, index_snapshots_v2) to exist first. '
'Run AFTER installing the new pgfr_record/install.sql. '
'Old data is preserved in _legacy tables — nothing is deleted.';
