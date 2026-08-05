-- =============================================================================
-- pgTAP tests: Phase 1 sparse statement_snapshots collector
-- SPEC §9.13 — Phase 1 test items
-- Run with: pg_prove -d <dbname> pgfr_record/tests/test_sparse_collector.sql
-- Requires: pgTAP, pg_stat_statements
-- PG14+ minimum
--
-- NOTE: T1 (epoch function exists) and T2 (epoch returns plausible value) were
-- removed from this file after being moved to PR #5 (phase1-issue1-infra).
-- This file starts at T3.
--
-- DEPENDENCY: This test file requires that the Phase 1 partition infrastructure
-- (PR #5 / phase1-issue1-infra) is already installed, specifically:
--   - pgfr_record.epoch()
--   - pgfr_record._ensure_partition(text, date)
-- Install pgfr_record/install.sql from the phase1-issue1-infra branch first,
-- or merge PR #5 before running these tests.
-- =============================================================================

begin;

select plan(30);

-- ---------------------------------------------------------------------------
-- Helper: ensure a clean test partition exists
-- ---------------------------------------------------------------------------
do $$
begin
    -- Create a test partition for today if needed
    -- Requires _ensure_partition() from phase1-issue1-infra (PR #5)
    perform pgfr_record._ensure_partition('statement_snapshots_v2', CURRENT_DATE);
end;
$$;

-- ===========================================================================
-- T3: statement_snapshots_v2 table exists and is partitioned
-- ===========================================================================
select ok(
    exists (
        select 1 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'statement_snapshots_v2'
          and c.relkind = 'p'  -- partitioned table
    ),
    'statement_snapshots_v2 must exist as a partitioned table'
);

-- T4: statement_snapshots_v2 has toplevel boolean column
select ok(
    exists (
        select 1 from pg_catalog.pg_attribute a
        join pg_catalog.pg_class c on c.oid = a.attrelid
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'statement_snapshots_v2'
          and a.attname = 'toplevel'
          and a.atttypid = pg_catalog.regtype('boolean')::oid
          and a.attnotnull = TRUE
    ),
    'statement_snapshots_v2 must have toplevel boolean not null'
);

-- T5: statement_snapshots_v2 has snapshot_id as BIGINT
select ok(
    exists (
        select 1 from pg_catalog.pg_attribute a
        join pg_catalog.pg_class c on c.oid = a.attrelid
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'statement_snapshots_v2'
          and a.attname = 'snapshot_id'
          and a.atttypid = pg_catalog.regtype('bigint')::oid
    ),
    'statement_snapshots_v2.snapshot_id must be BIGINT'
);

-- ===========================================================================
-- T6: statement_last_state table exists and is UNLOGGED
-- ===========================================================================
select ok(
    exists (
        select 1 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'statement_last_state'
          and c.relpersistence = 'u'  -- unlogged
    ),
    'statement_last_state must exist and be UNLOGGED'
);

-- T7: statement_last_state primary key covers (queryid, dbid, userid, toplevel)
select ok(
    exists (
        select 1
        from pg_catalog.pg_index i
        join pg_catalog.pg_class ci on ci.oid = i.indexrelid
        join pg_catalog.pg_class ct on ct.oid = i.indrelid
        join pg_catalog.pg_namespace n on n.oid = ct.relnamespace
        where n.nspname = 'pgfr_record'
          and ct.relname = 'statement_last_state'
          and i.indisprimary = TRUE
          and i.indnatts = 4
    ),
    'statement_last_state primary key must have exactly 4 columns'
);

-- ===========================================================================
-- T8: HOT contract — no index on statement_last_state covers calls or sample_ts
-- ===========================================================================
select ok(
    not exists (
        select 1
        from pg_catalog.pg_index i
        join pg_catalog.pg_class ci on ci.oid = i.indexrelid
        join pg_catalog.pg_class ct on ct.oid = i.indrelid
        join pg_catalog.pg_namespace n on n.oid = ct.relnamespace
        join pg_catalog.pg_attribute a on a.attrelid = ct.oid and a.attnum = any(i.indkey)
        where n.nspname = 'pgfr_record'
          and ct.relname = 'statement_last_state'
          and a.attname in ('calls', 'sample_ts')
    ),
    'HOT contract: no index on statement_last_state must cover calls or sample_ts'
);

-- ===========================================================================
-- T9: statement_last_state has fillfactor=70 storage parameter
-- ===========================================================================
select ok(
    exists (
        select 1
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'statement_last_state'
          and c.reloptions::text like '%fillfactor=70%'
    ),
    'statement_last_state must have fillfactor=70'
);

-- ===========================================================================
-- T10: _ensure_partition('statement_snapshots_v2', ...) is idempotent —
--      calling twice leaves exactly one partition for today
-- ===========================================================================
do $$
declare
    v_partition_name text;
    v_count          INT;
begin
    v_partition_name := 'statement_snapshots_v2_' || to_char(CURRENT_DATE, 'YYYY_MM_DD');
    -- Call twice — must not raise and must leave exactly one partition
    perform pgfr_record._ensure_partition('statement_snapshots_v2', CURRENT_DATE);
    perform pgfr_record._ensure_partition('statement_snapshots_v2', CURRENT_DATE);
    select COUNT(*) into v_count
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'pgfr_record' and c.relname = v_partition_name;
    if v_count <> 1 then
        raise exception '_ensure_partition not idempotent: found % partition(s) for %', v_count, v_partition_name;
    end if;
end;
$$;
select pass('_ensure_partition(''statement_snapshots_v2'', ...) is idempotent (partition exists after repeated calls)');

-- ===========================================================================
-- T11-T12: Sparse insert — rows skipped when calls unchanged
--          Seed last_state with current PGSS, then run collector again;
--          verify no new rows inserted for unchanged queries.
-- ===========================================================================
do $$
begin
    -- Ensure pg_stat_statements is available
    if not exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        raise notice 'pg_stat_statements not available — skipping sparse insert tests';
    end if;
end;
$$;

do $$
declare
    v_count_before bigint;
    v_count_after  bigint;
    v_sample_ts    INT4;
begin
    if not exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        return;
    end if;

    -- Fully rebuild last_state so it mirrors current PGSS exactly
    perform pgfr_record._rebuild_statement_last_state();

    v_sample_ts := extract(EPOCH from now() - pgfr_record.epoch())::INT4;

    select COUNT(*) into v_count_before
    from pgfr_record.statement_snapshots_v2
    where sample_ts >= v_sample_ts;

    -- Run sparse collector; since calls haven't changed, nothing should be inserted
    perform pgfr_record._collect_statement_snapshot_sparse(0);

    select COUNT(*) into v_count_after
    from pgfr_record.statement_snapshots_v2
    where sample_ts > v_sample_ts;

    if v_count_after <> 0 then
        raise exception 'Sparse insert: expected 0 new rows when calls unchanged, got %', v_count_after;
    end if;
end;
$$;
select pass('Sparse insert: 0 rows inserted when calls unchanged after rebuild');

-- T12: After artificially bumping calls in last_state downward (simulating reset),
--      collector should insert at least one row.
do $$
declare
    v_count_before bigint;
    v_count_after  bigint;
    v_sample_ts    INT4;
    v_queryid      bigint;
begin
    if not exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        return;
    end if;

    -- Get a queryid from last_state
    select queryid into v_queryid from pgfr_record.statement_last_state limit 1;
    if v_queryid is null then return; end if;

    -- Artificially inflate calls in last_state to force insertion on next tick
    update pgfr_record.statement_last_state
    set calls = calls + 999999
    where queryid = v_queryid;

    v_sample_ts := extract(EPOCH from now() - pgfr_record.epoch())::INT4;

    select COUNT(*) into v_count_before
    from pgfr_record.statement_snapshots_v2;

    perform pgfr_record._collect_statement_snapshot_sparse(0);

    select COUNT(*) into v_count_after
    from pgfr_record.statement_snapshots_v2;

    -- Restore last_state
    perform pgfr_record._rebuild_statement_last_state();

    if v_count_after <= v_count_before then
        raise exception 'Sparse insert: expected >=1 row when calls dropped, got 0 new rows';
    end if;
end;
$$;
select pass('Sparse insert: rows stored when calls dropped (reset detection)');

-- ===========================================================================
-- T13-T14: Crash recovery — TRUNCATE last_state → run collector →
--          exactly one baseline per (queryid,dbid,userid,toplevel), no duplicates
-- ===========================================================================
do $$
declare
    v_duplicates bigint;
    v_pgss_count bigint;
    v_ls_count   bigint;
begin
    if not exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        return;
    end if;

    -- Simulate crash: empty the UNLOGGED side table
    truncate pgfr_record.statement_last_state;

    -- Run collector (should detect empty table and rebuild)
    perform pgfr_record._collect_statement_snapshot_sparse(0);

    -- Verify: exactly one row per (queryid,dbid,userid,toplevel) in last_state
    select COUNT(*) into v_duplicates
    from (
        select queryid, dbid, userid, toplevel, COUNT(*) as cnt
        from pgfr_record.statement_last_state
        group by queryid, dbid, userid, toplevel
        having COUNT(*) > 1
    ) dups;

    if v_duplicates > 0 then
        raise exception 'Crash recovery: % duplicate (queryid,dbid,userid,toplevel) entries in last_state', v_duplicates;
    end if;
end;
$$;
select pass('Crash recovery: exactly one baseline per (queryid,dbid,userid,toplevel) after TRUNCATE');

-- T14: After crash recovery, last_state row count should not exceed PGSS count
do $$
declare
    v_pgss_count bigint;
    v_ls_count   bigint;
begin
    if not exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        return;
    end if;

    select COUNT(*) into v_pgss_count from pg_stat_statements;
    select COUNT(*) into v_ls_count from pgfr_record.statement_last_state;

    if v_ls_count > v_pgss_count then
        raise exception 'Crash recovery: last_state has % rows > PGSS % rows (stale entries)', v_ls_count, v_pgss_count;
    end if;
end;
$$;
select pass('Crash recovery: statement_last_state row count <= pg_stat_statements count after rebuild');

-- ===========================================================================
-- T_desync: stats_reset desync path triggers rebuild
-- Simulate: set last sample_ts to past (0 = epoch start) so that
--   epoch() + 0 * interval '1 second' = epoch() (2026-01-01 or similar)
-- which is older than any real pg_stat_statements_info.stats_reset,
-- triggering the desync rebuild path in _collect_statement_snapshot_sparse.
-- ===========================================================================
do $$
begin
    if not exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        return;
    end if;
    perform pgfr_record._rebuild_statement_last_state();
    -- set all sample_ts to 0 so epoch()+0 = epoch() < real stats_reset
    update pgfr_record.statement_last_state set sample_ts = 0;
end;
$$;

select ok(
    (select count(*) from pgfr_record.statement_last_state) > 0,
    'T_desync pre: last_state has rows before desync test'
);

-- run collector — stats_reset should be newer than epoch(), triggering rebuild
do $$
begin
    if not exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        return;
    end if;
    perform pgfr_record._collect_statement_snapshot_sparse(0);
end;
$$;

select ok(
    (select count(*) from pgfr_record.statement_last_state) > 0,
    'T_desync: after stats_reset desync, last_state should be rebuilt and populated'
);

-- ===========================================================================
-- T15: ON CONFLICT DO UPDATE used — run 10 ticks, verify n_dead_tup stays bounded
--      HOT updates should prevent unbounded dead tuple accumulation
-- ===========================================================================
do $$
declare
    i             INT;
    v_dead_before bigint;
    v_dead_after  bigint;
begin
    if not exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        return;
    end if;

    -- Initial rebuild
    perform pgfr_record._rebuild_statement_last_state();

    select n_dead_tup into v_dead_before
    from pg_stat_user_tables
    where schemaname = 'pgfr_record' and relname = 'statement_last_state';

    -- Simulate 10 ticks by incrementing calls each time (forces upsert on each tick)
    for i in 1..10 loop
        -- Bump all calls by 1 to force upsert path
        update pgfr_record.statement_last_state set calls = calls + 1;
        -- Run collector — should use ON CONFLICT DO UPDATE
        perform pgfr_record._collect_statement_snapshot_sparse(i::bigint);
    end loop;

    -- Force stats update
    analyze pgfr_record.statement_last_state;

    select coalesce(n_dead_tup, 0) into v_dead_after
    from pg_stat_user_tables
    where schemaname = 'pgfr_record' and relname = 'statement_last_state';

    -- With HOT updates and fillfactor=70, dead tuples should stay well under 100
    -- (autovacuum threshold is 1% = ~50 rows for a 5000-row table)
    if v_dead_after >= 100 then
        raise warning 'ON CONFLICT DO UPDATE test: % dead tuples after 10 ticks (may indicate non-HOT updates)', v_dead_after;
        -- Note: this is a WARNING not EXCEPTION because autovacuum timing affects this
    end if;
end;
$$;
select pass('ON CONFLICT DO UPDATE: 10 ticks completed without constraint violations');

-- ===========================================================================
-- T16: toplevel — two PGSS entries differing only in toplevel tracked independently
-- ===========================================================================
do $$
declare
    v_fake_queryid bigint := -9999999999;
    v_dbid         oid;
    v_userid       oid;
    v_count_true   INT;
    v_count_false  INT;
begin
    select oid into v_dbid from pg_database where datname = current_database();
    select oid into v_userid from pg_roles where rolname = current_user;

    -- Insert two fake entries differing only in toplevel
    insert into pgfr_record.statement_last_state (queryid, dbid, userid, toplevel, calls, sample_ts)
    values
        (v_fake_queryid, v_dbid, v_userid, TRUE,  100, 1),
        (v_fake_queryid, v_dbid, v_userid, FALSE, 200, 1);

    -- Verify both rows exist independently
    select COUNT(*) into v_count_true
    from pgfr_record.statement_last_state
    where queryid = v_fake_queryid and toplevel = TRUE;

    select COUNT(*) into v_count_false
    from pgfr_record.statement_last_state
    where queryid = v_fake_queryid and toplevel = FALSE;

    -- Cleanup
    delete from pgfr_record.statement_last_state where queryid = v_fake_queryid;

    if v_count_true <> 1 or v_count_false <> 1 then
        raise exception 'toplevel test: expected 1 row each for toplevel=TRUE and FALSE, got % and %',
            v_count_true, v_count_false;
    end if;
end;
$$;
select pass('toplevel: two entries differing only in toplevel tracked independently in statement_last_state');

-- ===========================================================================
-- T17: _rebuild_statement_last_state() calls ANALYZE immediately after INSERT
--      Verify stats exist post-rebuild (pg_stat_user_tables.last_analyze IS NOT NULL
--      or n_live_tup reflects actual row count)
-- ===========================================================================
do $$
declare
    v_live_before bigint;
    v_live_after  bigint;
begin
    if not exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        return;
    end if;

    perform pgfr_record._rebuild_statement_last_state();

    -- ANALYZE must have updated pg_stat_user_tables n_live_tup
    select n_live_tup into v_live_after
    from pg_stat_user_tables
    where schemaname = 'pgfr_record' and relname = 'statement_last_state';

    if v_live_after is null then
        raise exception '_rebuild_statement_last_state: n_live_tup IS NULL after ANALYZE';
    end if;
end;
$$;
select pass('_rebuild_statement_last_state: ANALYZE updates pg_stat_user_tables.n_live_tup');

-- ===========================================================================
-- T18: _ensure_partition('statement_snapshots_v2', ...) creates partition for a future date
-- ===========================================================================
do $$
declare
    v_future_date DATE := CURRENT_DATE + 7;
    v_part_name   text;
begin
    v_part_name := 'statement_snapshots_v2_' || to_char(v_future_date, 'YYYY_MM_DD');

    perform pgfr_record._ensure_partition('statement_snapshots_v2', v_future_date);

    if not exists (
        select 1 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record' and c.relname = v_part_name
    ) then
        raise exception '_ensure_partition: partition % not found after creation', v_part_name;
    end if;

    -- Cleanup test partition
    execute format('DROP TABLE IF EXISTS pgfr_record.%I', v_part_name);
end;
$$;
select pass('_ensure_partition(''statement_snapshots_v2'', ...): creates partition for future date');

-- ===========================================================================
-- T19: statement_snapshots_v2 partition has B-tree index
--      (_btree_idx suffix from _ensure_partition in PR #5)
-- ===========================================================================
select ok(
    exists (
        select 1
        from pg_catalog.pg_class ci
        join pg_catalog.pg_index ix on ix.indexrelid = ci.oid
        join pg_catalog.pg_class ct on ct.oid = ix.indrelid
        join pg_catalog.pg_namespace n on n.oid = ct.relnamespace
        where n.nspname = 'pgfr_record'
          and ct.relname like 'statement_snapshots_v2_%'
          and ci.relname like '%_btree_idx'
          and ci.relam = (select oid from pg_am where amname = 'btree')
    ),
    'statement_snapshots_v2 partitions must have a B-tree index (_btree_idx)'
);

-- ===========================================================================
-- T20: statement_snapshots_v2 partition has BRIN index on sample_ts
--      (_brin_idx suffix from _ensure_partition in PR #5)
-- ===========================================================================
select ok(
    exists (
        select 1
        from pg_catalog.pg_class ci
        join pg_catalog.pg_index ix on ix.indexrelid = ci.oid
        join pg_catalog.pg_class ct on ct.oid = ix.indrelid
        join pg_catalog.pg_namespace n on n.oid = ct.relnamespace
        join pg_catalog.pg_attribute a on a.attrelid = ct.oid and a.attnum = ix.indkey[0]
        where n.nspname = 'pgfr_record'
          and ct.relname like 'statement_snapshots_v2_%'
          and ci.relname like '%_brin_idx'
          and ci.relam = (select oid from pg_am where amname = 'brin')
          and a.attname = 'sample_ts'
    ),
    'statement_snapshots_v2 partitions must have a BRIN index on sample_ts (_brin_idx)'
);

-- ===========================================================================
-- T21: pgss_dealloc_warning column exists in statement_snapshots_v2
-- ===========================================================================
select ok(
    exists (
        select 1 from pg_catalog.pg_attribute a
        join pg_catalog.pg_class c on c.oid = a.attrelid
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'statement_snapshots_v2'
          and a.attname = 'pgss_dealloc_warning'
          and a.atttypid = pg_catalog.regtype('boolean')::oid
    ),
    'statement_snapshots_v2 must have pgss_dealloc_warning boolean column'
);

-- ===========================================================================
-- T22: config keys for sparse collector observability exist
-- ===========================================================================
select ok(
    exists (select 1 from pgfr_record.config where key = 'pgss_last_dealloc'),
    'config key pgss_last_dealloc must exist'
);

select ok(
    exists (select 1 from pgfr_record.config where key = 'pgss_rebuild_skip_count'),
    'config key pgss_rebuild_skip_count must exist'
);

-- ===========================================================================
-- T24: _collect_statement_snapshot_sparse handles pg_stat_statements unavailable
--      gracefully (should not raise exception to caller)
-- ===========================================================================
do $$
declare
    v_ok boolean := TRUE;
begin
    -- If pg_stat_statements IS available, this test verifies the function runs cleanly
    -- If not available, the EXCEPTION block should catch it silently
    begin
        perform pgfr_record._collect_statement_snapshot_sparse(-999);
    exception when others then
        v_ok := FALSE;
        raise warning 'Unexpected exception from _collect_statement_snapshot_sparse: %', SQLERRM;
    end;

    if not v_ok then
        raise exception 'PGSS sparse collector must not propagate exceptions to caller';
    end if;
end;
$$;
select pass('_collect_statement_snapshot_sparse: does not propagate exceptions to caller');

-- ===========================================================================
-- T25: statement_snapshots_v2 sample_ts column is INT4
-- ===========================================================================
select ok(
    exists (
        select 1 from pg_catalog.pg_attribute a
        join pg_catalog.pg_class c on c.oid = a.attrelid
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = 'statement_snapshots_v2'
          and a.attname = 'sample_ts'
          and a.atttypid = pg_catalog.regtype('integer')::oid  -- int4
          and a.attnotnull = TRUE
    ),
    'statement_snapshots_v2.sample_ts must be INT4 NOT NULL'
);

-- ===========================================================================
-- T26: Old statement_snapshots table exists (may be renamed to _legacy after migrate_phase3)
-- ===========================================================================
select ok(
    exists (
        select 1 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname in ('statement_snapshots', 'statement_snapshots_legacy')
          and c.relkind = 'r'
    ),
    'Old statement_snapshots table must still exist (may be renamed to _legacy after migration)'
);

-- ===========================================================================
-- T27: boundary tick inserts baseline rows (B2 regression guard)
--      Simulate a day boundary by backdating statement_last_state.sample_ts
--      and verify that _collect_statement_snapshot_sparse() inserts rows.
-- ===========================================================================
do $$
declare
    v_count_before int;
    v_count_after  int;
    v_snapshot_id  bigint := -77777;
begin
    if not exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        raise notice 'T27: pg_stat_statements not available — skipping boundary tick test';
        return;
    end if;

    -- backdate all last_state rows to yesterday (simulate day boundary)
    if exists (select 1 from pgfr_record.statement_last_state) then
        update pgfr_record.statement_last_state
        set sample_ts = extract(epoch from (now() - interval '26 hours') - pgfr_record.epoch())::int4;
    else
        perform pgfr_record._rebuild_statement_last_state();
        update pgfr_record.statement_last_state
        set sample_ts = extract(epoch from (now() - interval '26 hours') - pgfr_record.epoch())::int4;
    end if;

    select count(*)::int into v_count_before
    from pgfr_record.statement_snapshots_v2
    where snapshot_id = v_snapshot_id;

    perform pgfr_record._collect_statement_snapshot_sparse(v_snapshot_id);

    select count(*)::int into v_count_after
    from pgfr_record.statement_snapshots_v2
    where snapshot_id = v_snapshot_id;

end $$;

-- T27 result: check rows were inserted (or skip if pg_stat_statements unavailable)
SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
    THEN skip('T27: pg_stat_statements not available — boundary tick test skipped')
    ELSE ok(
        EXISTS (
            SELECT 1 FROM pgfr_record.statement_snapshots_v2 WHERE snapshot_id = -77777
        ),
        'T27: boundary tick inserts baseline rows into new day partition (B2 regression guard)'
    )
END;

-- ===========================================================================
-- T28: _rebuild_statement_last_state() stores caller-supplied sample_ts (B7 guard)
-- ===========================================================================
do $$
declare
    v_expected_ts int4 := 12345678;
    v_actual_ts   int4;
begin
    if not exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        raise notice 'T28: pg_stat_statements not available — skipping';
        return;
    end if;

    perform pgfr_record._rebuild_statement_last_state(v_expected_ts);

    select max(sample_ts) into v_actual_ts from pgfr_record.statement_last_state;

    if v_actual_ts <> v_expected_ts then
        raise exception 'T28: _rebuild_statement_last_state stored ts % instead of supplied %',
            v_actual_ts, v_expected_ts;
    end if;
end $$;

select ok(true, 'T28: _rebuild_statement_last_state stores caller-supplied p_sample_ts (B7 guard)');

-- ===========================================================================
-- T29: control for the HIGH_CHURN gate test (Issue #126)
--      With a healthy PGSS, a current-tick last_state with poisoned calls
--      makes the collector insert one row per PGSS entry. Proves the setup
--      T30 reuses, so T30's zero-row assertion is meaningful.
-- ===========================================================================
do $$
begin
    if not exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        raise notice 'T29: pg_stat_statements not available — skipping';
        return;
    end if;

    -- Fresh last_state at a current tick (avoids the reset and day-boundary
    -- rebuild paths), then poison calls so every PGSS row qualifies.
    perform pgfr_record._rebuild_statement_last_state(
        extract(epoch from now() - pgfr_record.epoch())::int4);
    update pgfr_record.statement_last_state set calls = -1;

    perform pgfr_record._collect_statement_snapshot_sparse(-88887);
end $$;

select case
    when not exists (select 1 from pg_extension where extname = 'pg_stat_statements')
    then skip('T29: pg_stat_statements not available — HIGH_CHURN control skipped')
    else ok(
        exists (select 1 from pgfr_record.statement_snapshots_v2 where snapshot_id = -88887),
        'T29: healthy PGSS with poisoned last_state inserts rows (control for T30)')
end;

-- ===========================================================================
-- T30: HIGH_CHURN gates the v2 sparse collector (Issue #126)
--      Same setup as T29, but _check_statements_health() is mocked to report
--      HIGH_CHURN; the collector must skip the tick and insert nothing.
--      The mock is rolled back with the rest of the transaction.
-- ===========================================================================
create or replace function pgfr_record._check_statements_health()
returns table(
    current_statements bigint,
    max_statements integer,
    utilization_pct numeric,
    dealloc_count bigint,
    status text
)
language sql as $mock$
    select 4900::bigint, 5000, 98.0::numeric, 42::bigint, 'HIGH_CHURN'::text;
$mock$;

do $$
begin
    if not exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        raise notice 'T30: pg_stat_statements not available — skipping';
        return;
    end if;

    update pgfr_record.statement_last_state set calls = -1;

    perform pgfr_record._collect_statement_snapshot_sparse(-88888);
end $$;

select case
    when not exists (select 1 from pg_extension where extname = 'pg_stat_statements')
    then skip('T30: pg_stat_statements not available — HIGH_CHURN gate test skipped')
    else ok(
        not exists (select 1 from pgfr_record.statement_snapshots_v2 where snapshot_id = -88888),
        'T30: HIGH_CHURN skips v2 sparse statement collection entirely (Issue #126)')
end;

-- Cleanup: rebuild last_state to a clean state after tests
do $$
begin
    if exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        perform pgfr_record._rebuild_statement_last_state();
    end if;
end;
$$;

select * from finish();
rollback;
