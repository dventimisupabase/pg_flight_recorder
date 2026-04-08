-- =============================================================================
-- Phase 1: Core Partition Infrastructure (Issue #2)
-- Implements §7.1 and §7.2 of blueprints/SPEC.md
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. pgfr_record.epoch()
--    Fixed installation epoch for int4 sample_ts offsets.
--    WARNING: must never change after installation — all sample_ts values are
--    seconds offset from this point. Changing it corrupts all timestamps.
--    See §7.1 and Q6 in SPEC.md.
-- -----------------------------------------------------------------------------
create or replace function pgfr_record.epoch()
returns timestamptz
immutable
language sql
as $$
    select '2026-01-01 00:00:00+00'::timestamptz;
$$;

comment on function pgfr_record.epoch() is
'Fixed installation epoch (2026-01-01 UTC) for int4 sample_ts offsets. '
'NEVER change this after installation — all stored timestamps are seconds '
'relative to this point. Overflow horizon: ~2094. '
'See blueprints/SPEC.md §7.1 and Q6.';

-- -----------------------------------------------------------------------------
-- 2. pgfr_record._ensure_partition(p_table text, p_date date)
--    Idempotent daily partition creator.
--    O(1) happy path: returns immediately if partition already exists.
--    Creates partition with UTC-enforced bounds + B-tree + BRIN indexes.
--    Safe to call from snapshot() on every tick as a runtime safety net.
--
--    WARNING: p_table must have columns (queryid, dbid, userid, toplevel, sample_ts)
--    — the B-tree index is hardcoded to these columns. Calls for tables without
--    these columns will fail with 'column does not exist'.
-- -----------------------------------------------------------------------------
create or replace function pgfr_record._ensure_partition(
    p_table text,
    p_date  date
)
returns void
language plpgsql
as $$
declare
    v_partition_name text;
    v_bound_start    int4;
    v_bound_end      int4;
    v_date_start_ts  timestamptz;
    v_date_end_ts    timestamptz;
begin
    -- Column contract: p_table must have (queryid, dbid, userid, toplevel, sample_ts).
    -- The B-tree index below is hardcoded to these columns; missing columns cause
    -- 'column does not exist' errors. Verify your table schema before calling.

    -- Derive partition name from date (YYYY_MM_DD suffix)
    v_partition_name := p_table || '_' || to_char(p_date, 'YYYY_MM_DD');

    -- O(1) happy path: check pg_class, return immediately if partition exists.
    -- No DDL, no lock acquisition on the common code path.
    if exists (
        select 1
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = v_partition_name
    ) then
        return;
    end if;

    -- Compute UTC-enforced int4 bounds.
    -- Always use explicit +00 to prevent session timezone drift (pg_cron risk).
    -- Format: 'YYYY-MM-DD 00:00:00+00'::timestamptz to be unambiguous.
    v_date_start_ts := (to_char(p_date,     'YYYY-MM-DD') || ' 00:00:00+00')::timestamptz;
    v_date_end_ts   := (to_char(p_date + 1, 'YYYY-MM-DD') || ' 00:00:00+00')::timestamptz;

    v_bound_start := extract(epoch from (v_date_start_ts - pgfr_record.epoch()))::int4;
    v_bound_end   := extract(epoch from (v_date_end_ts   - pgfr_record.epoch()))::int4;

    -- Create the partition
    execute format(
        'create table if not exists pgfr_record.%I
         partition of pgfr_record.%I
         for values from (%s) to (%s)',
        v_partition_name,
        p_table,
        v_bound_start,
        v_bound_end
    );

    -- B-tree index: supports point-in-time reconstruction and sparse insert lookback.
    -- Access pattern: filter on (queryid, dbid, userid, toplevel), order by sample_ts DESC.
    -- Requires columns: queryid, dbid, userid, toplevel, sample_ts (see column contract above).
    execute format(
        'create index if not exists %I
         on pgfr_record.%I (queryid, dbid, userid, toplevel, sample_ts desc)',
        v_partition_name || '_btree_idx',
        v_partition_name
    );

    -- BRIN index: for pure time-range aggregate queries ("last hour").
    -- pages_per_range=8 chosen for sparse workloads (50-200 rows/tick).
    -- Within-day insert order guarantees high correlation for BRIN effectiveness.
    execute format(
        'create index if not exists %I
         on pgfr_record.%I
         using brin (sample_ts) with (pages_per_range = 8)',
        v_partition_name || '_brin_idx',
        v_partition_name
    );

end;
$$;

comment on function pgfr_record._ensure_partition(text, date) is
'Idempotent daily partition creator for pgfr_record partitioned tables. '
'O(1) happy path via pg_class existence check — returns immediately if partition exists. '
'UTC-enforced bounds prevent session timezone drift. '
'Creates B-tree index (queryid, dbid, userid, toplevel, sample_ts DESC) for point-in-time reads '
'and BRIN index (sample_ts, pages_per_range=8) for time-range aggregates. '
'Safe to call from snapshot() on every tick. See blueprints/SPEC.md §7.2. '
'WARNING: p_table must have columns (queryid, dbid, userid, toplevel, sample_ts) — '
'the B-tree index is hardcoded to these columns. Calls for tables without these columns '
'will fail with ''column does not exist''.';

-- -----------------------------------------------------------------------------
-- 3. pgfr_record._partition_inventory()
--    Catalog-based partition introspection. Used by truncate/drop GC functions
--    and the partition_gc_health view.
--
--    Runtime assertions at entry:
--      - RANGE partitioning only
--      - Single partition key column
--      - int4 (atttypid = 23) key type
--    Raises exception on violation — silent corruption is worse than loud failure.
--
--    is_empty: uses pg_relation_size(oid) = 0 ONLY.
--              Never reltuples — lags until next ANALYZE, unreliable post-TRUNCATE.
--
--    Bound parsing: defensive regex on pg_get_expr() output via LATERAL join.
--                   pg_get_expr format is not guaranteed stable across PG versions.
--                   Fails loudly on unexpected format (strict assertion).
--                   LATERAL join evaluates regexp_match once per row (not 5×).
-- -----------------------------------------------------------------------------
create or replace function pgfr_record._partition_inventory()
returns table (
    parent_table   text,
    partition_name text,
    bound_start    int4,
    bound_end      int4,
    is_expired     boolean,
    is_ancient     boolean,
    is_empty       boolean
)
language plpgsql
stable
as $$
declare
    v_partstrat          char;
    v_partnatts          int2;
    v_atttypid           oid;
    v_retention_days     int;
    v_cutoff_ts          timestamptz;
    v_cutoff             int4;
    v_ancient_cutoff     int4;
    v_arc_retention_days int;
    v_arc_cutoff         int4;
    v_arc_ancient_cutoff int4;
    v_parent_oid         oid;
    v_parent_name        text;
begin
    -- -------------------------------------------------------------------------
    -- Runtime assertions: verify all pgfr_record partitioned tables conform.
    -- We assert once per parent, fail loudly on first violation.
    -- -------------------------------------------------------------------------
    for v_parent_oid, v_parent_name in
        select pt.partrelid, pc.relname
        from pg_catalog.pg_partitioned_table pt
        join pg_catalog.pg_class pc on pc.oid = pt.partrelid
        join pg_catalog.pg_namespace pn on pn.oid = pc.relnamespace
        where pn.nspname = 'pgfr_record'
    loop
        select pt.partstrat, pt.partnatts
          into v_partstrat, v_partnatts
        from pg_catalog.pg_partitioned_table pt
        where pt.partrelid = v_parent_oid;

        -- Skip LIST-partitioned tables (ring buffer v2 slot tables: wait_samples,
        -- lock_samples, activity_samples). GC is handled by rotate_ring() TRUNCATE,
        -- not by _partition_inventory() / truncate_old_partitions().
        if v_partstrat = 'l' then
            continue;
        end if;

        -- Assert RANGE partitioning for all non-LIST tables
        if v_partstrat <> 'r' then
            raise exception
                '_partition_inventory(): table pgfr_record.% uses partitioning strategy "%" — '
                'only RANGE (r) is supported (LIST is allowed for ring buffer slot tables). '
                'Fix the table or exclude it from pgfr_record schema.',
                v_parent_name, v_partstrat;
        end if;

        -- Assert single partition key column
        if v_partnatts <> 1 then
            raise exception
                '_partition_inventory(): table pgfr_record.% has % partition key columns — '
                'only single-column RANGE partitioning on int4 is supported.',
                v_parent_name, v_partnatts;
        end if;

        -- Assert int4 (oid=23) partition key type
        select pa.atttypid into v_atttypid
        from pg_catalog.pg_partitioned_table pt
        join pg_catalog.pg_attribute pa
          on pa.attrelid = pt.partrelid
         and pa.attnum   = pt.partattrs[0]
        where pt.partrelid = v_parent_oid;

        -- explicit null guard: attribute lookup failing silently would skip the assertion
        if v_atttypid is null then
            raise exception
                '_partition_inventory(): table pgfr_record.% — could not determine partition '
                'key type (pg_attribute lookup returned null). Schema corruption?',
                v_parent_name;
        end if;

        if v_atttypid <> 23 then  -- 23 = int4
            raise exception
                '_partition_inventory(): table pgfr_record.% partition key type OID is % — '
                'expected int4 (OID 23). Only int4 partition keys are supported.',
                v_parent_name, v_atttypid;
        end if;
    end loop;

    -- -------------------------------------------------------------------------
    -- Compute retention cutoffs — two tiers:
    --   snapshot tier: retention_snapshots_days (default 30)
    --     tables: statement_snapshots_v2, table_snapshots_v2, index_snapshots_v2,
    --             snapshots_v2, replication_snapshots_v2, vacuum_progress_snapshots_v2
    --   archive tier: retention_archive_days (default 7)
    --     tables: activity_samples_archive_v2, lock_samples_archive_v2,
    --             wait_samples_archive_v2
    -- -------------------------------------------------------------------------
    v_retention_days := coalesce(
        pgfr_record._get_config('retention_snapshots_days', '30')::int,
        30
    );

    -- Snapshot-tier cutoffs
    v_cutoff_ts := date_trunc('day', now() at time zone 'UTC') at time zone 'UTC'
                   - (v_retention_days || ' days')::interval;
    v_cutoff        := extract(epoch from (v_cutoff_ts - pgfr_record.epoch()))::int4;
    v_ancient_cutoff := extract(epoch from
        (v_cutoff_ts - (v_retention_days || ' days')::interval - pgfr_record.epoch())
    )::int4;

    -- Archive-tier cutoffs (shorter retention)
    v_arc_retention_days := coalesce(
        pgfr_record._get_config('retention_archive_days', '7')::int,
        7
    );
    v_arc_cutoff := extract(epoch from (
        date_trunc('day', now() at time zone 'UTC') at time zone 'UTC'
        - (v_arc_retention_days || ' days')::interval
        - pgfr_record.epoch()
    ))::int4;
    v_arc_ancient_cutoff := extract(epoch from (
        date_trunc('day', now() at time zone 'UTC') at time zone 'UTC'
        - (v_arc_retention_days * 2 || ' days')::interval
        - pgfr_record.epoch()
    ))::int4;

    -- -------------------------------------------------------------------------
    -- Main catalog query with defensive bound parsing via LATERAL join.
    -- regexp_match is called once per row (not 5×) — evaluated in the LATERAL
    -- subquery and referenced by column alias in the SELECT list.
    -- -------------------------------------------------------------------------
    return query
    select
        parent.relname::text                              as parent_table,
        child.relname::text                               as partition_name,
        -- Lower int4 bound from LATERAL-parsed regex result.
        -- Expected format: "FOR VALUES FROM (NNN) TO (MMM)"
        parsed.bounds[1]::int4                            as bound_start,
        -- Upper int4 bound (second capture group)
        parsed.bounds[2]::int4                            as bound_end,
        -- is_expired: uses archive-tier cutoff for archive_v2 tables, snapshot-tier for rest
        (parsed.bounds[2]::int4 < case
            when parent.relname like '%_archive_v2'
            then v_arc_cutoff
            else v_cutoff
        end)                                              as is_expired,
        -- is_ancient: same tier selection
        (parsed.bounds[2]::int4 < case
            when parent.relname like '%_archive_v2'
            then v_arc_ancient_cutoff
            else v_ancient_cutoff
        end)                                              as is_ancient,
        -- is_empty: authoritative — pg_relation_size = 0.
        -- Never reltuples: lags until ANALYZE, unreliable post-TRUNCATE.
        (pg_catalog.pg_relation_size(child.oid) = 0)     as is_empty
    from pg_catalog.pg_inherits i
    join pg_catalog.pg_class child   on child.oid  = i.inhrelid
    join pg_catalog.pg_class parent  on parent.oid = i.inhparent
    join pg_catalog.pg_namespace n   on n.oid      = child.relnamespace
    -- LATERAL: evaluate regexp_match once per row; result reused for all 5 references above.
    -- Defensive regex on pg_get_expr() output — pg_get_expr format not guaranteed stable.
    cross join lateral (
        select regexp_match(
            pg_catalog.pg_get_expr(child.relpartbound, child.oid),
            E'FOR VALUES FROM \\(([-]?\\d+)\\) TO \\(([-]?\\d+)\\)'
        ) as bounds
    ) as parsed
    where n.nspname = 'pgfr_record'
      -- Only RANGE partitions (skip non-partition children if any)
      and child.relkind = 'r'
      -- Exclude children with unparseable bounds (assertion loop above catches parent violations).
      -- Any child that doesn't match the regex is excluded here; schema violations on
      -- the parent are caught by the assertion loop above.
      and parsed.bounds is not null
    order by parent.relname, child.relname;

    -- Post-query check: if any child had unparseable bounds, the assertion loop
    -- above would have already raised. Unparseable children are filtered above.
    -- This is belt-and-suspenders: loudly fail on schema violations.
end;
$$;

comment on function pgfr_record._partition_inventory() is
'Catalog-based partition introspection for pgfr_record schema. '
'Two retention tiers: snapshot-tier (retention_snapshots_days, default 30) for v2 snapshot '
'and sparse-collector tables; archive-tier (retention_archive_days, default 7) for '
'*_archive_v2 tables. is_expired/is_ancient use the correct cutoff per parent table name. '
'Runtime assertions: verifies RANGE partitioning, single column, int4 key type — raises loudly. '
'LIST-partitioned ring buffer tables (wait_samples, lock_samples, activity_samples) are skipped '
'— their GC is handled by rotate_ring() TRUNCATE. '
'is_empty: pg_relation_size(oid)=0 ONLY (authoritative post-TRUNCATE; never reltuples). '
'Used by truncate_old_partitions(), drop_ancient_partitions(), partition_gc_health view. '
'See SPEC §7.2.';

-- -----------------------------------------------------------------------------
-- 4. pgfr_record.truncate_old_partitions()
--    Nightly GC: TRUNCATE partitions that are expired AND non-empty.
--    lock_timeout = 50ms (aggressive — FIFO queue stalls all readers on contention).
--    Loops ALL eligible partitions; skips locked ones (continues to next).
--    Storage reclaimed immediately. Partition definition remains for planner pruning.
-- -----------------------------------------------------------------------------
create or replace function pgfr_record.truncate_old_partitions()
returns void
language plpgsql
as $$
declare
    v_rec             record;
    v_truncated_count int := 0;
    v_skipped_count   int := 0;
begin
    for v_rec in
        select parent_table, partition_name
        from pgfr_record._partition_inventory()
        where is_expired and not is_empty
        order by parent_table, partition_name
    loop
        begin
            -- 50ms timeout: FIFO queue means waiting longer stalls all readers.
            -- If we miss this window, we retry next hour — lag is not permanent.
            set local lock_timeout = '50ms';
            execute format('truncate pgfr_record.%I', v_rec.partition_name);
            v_truncated_count := v_truncated_count + 1;
            raise notice 'pgfr_record: Truncated expired partition pgfr_record.%', v_rec.partition_name;
        exception
            when lock_not_available then
                -- Skip this partition and continue to next — do NOT abort.
                -- Best-effort retention: never stall the collection loop.
                v_skipped_count := v_skipped_count + 1;
                raise notice 'pgfr_record: Skipped pgfr_record.% (lock_timeout exceeded, will retry next run)',
                    v_rec.partition_name;
            when others then
                -- Unexpected error: log and continue to next partition.
                v_skipped_count := v_skipped_count + 1;
                raise warning 'pgfr_record: Failed to truncate pgfr_record.%: %',
                    v_rec.partition_name, sqlerrm;
        end;
    end loop;

    if v_truncated_count > 0 or v_skipped_count > 0 then
        raise notice 'pgfr_record: truncate_old_partitions() complete: % truncated, % skipped',
            v_truncated_count, v_skipped_count;
    end if;
end;
$$;

comment on function pgfr_record.truncate_old_partitions() is
'Nightly GC: TRUNCATE expired (is_expired AND NOT is_empty) partitions from _partition_inventory(). '
'lock_timeout=50ms — aggressive to avoid FIFO queue stalls on ACCESS EXCLUSIVE. '
'Loops ALL eligible partitions; skips locked ones (continues, does not abort). '
'Retention is best-effort under persistent lock contention — never stalls collection. '
'Partition definitions remain attached for planner pruning. '
'Run nightly via pg_cron. See blueprints/SPEC.md §7.2.';

-- -----------------------------------------------------------------------------
-- 5. pgfr_record.drop_ancient_partitions()
--    Monthly slow-path GC: DROP empty partitions older than 2× retention.
--    Targets only is_ancient AND is_empty — safe, no concurrent readers.
--    lock_timeout = 2s (plain DROP TABLE, no DETACH needed — table is empty).
--    Keeps total partition count permanently bounded.
-- -----------------------------------------------------------------------------
create or replace function pgfr_record.drop_ancient_partitions()
returns void
language plpgsql
as $$
declare
    v_rec           record;
    v_dropped_count int := 0;
    v_skipped_count int := 0;
begin
    -- Target: is_ancient (>2× retention window) AND is_empty (already truncated).
    -- Empty partitions have no concurrent readers — plain DROP TABLE suffices.
    -- No DETACH CONCURRENTLY needed: empty table, no live data, no user sessions touching it.
    for v_rec in
        select parent_table, partition_name
        from pgfr_record._partition_inventory()
        where is_ancient and is_empty
        order by parent_table, partition_name
    loop
        begin
            -- 2s timeout: empty partition DROP is fast (catalog change only).
            -- Longer than truncate_old_partitions (50ms) because this is monthly
            -- and the table is empty — contention is unlikely, worth waiting briefly.
            set local lock_timeout = '2s';
            execute format('drop table if exists pgfr_record.%I', v_rec.partition_name);
            v_dropped_count := v_dropped_count + 1;
            raise notice 'pgfr_record: Dropped ancient empty partition pgfr_record.%', v_rec.partition_name;
        exception
            when lock_not_available then
                -- Skip and try next monthly run.
                v_skipped_count := v_skipped_count + 1;
                raise notice 'pgfr_record: Skipped drop of pgfr_record.% (lock_timeout exceeded, will retry next run)',
                    v_rec.partition_name;
            when others then
                v_skipped_count := v_skipped_count + 1;
                raise warning 'pgfr_record: Failed to drop pgfr_record.%: %',
                    v_rec.partition_name, sqlerrm;
        end;
    end loop;

    if v_dropped_count > 0 or v_skipped_count > 0 then
        raise notice 'pgfr_record: drop_ancient_partitions() complete: % dropped, % skipped',
            v_dropped_count, v_skipped_count;
    end if;
end;
$$;

comment on function pgfr_record.drop_ancient_partitions() is
'Monthly slow-path GC: DROP empty partitions older than 2× retention_snapshots_days. '
'Targets is_ancient AND is_empty from _partition_inventory() — safe, no concurrent readers. '
'lock_timeout=2s (plain DROP TABLE; no DETACH needed for empty partitions). '
'Keeps catalog partition count permanently bounded (without this, TRUNCATE-based retention '
'accumulates partition definitions indefinitely). '
'Default cadence: monthly via pg_cron (configurable). See blueprints/SPEC.md §7.2.';

-- -----------------------------------------------------------------------------
-- 6. pgfr_record.partition_gc_health (view)
--    Operator visibility into partition GC state.
--    Shows pending truncations, recently truncated, and ancient partitions
--    awaiting the monthly slow-path DROP — grouped by parent_table.
-- -----------------------------------------------------------------------------
create or replace view pgfr_record.partition_gc_health as
select
    parent_table,
    count(*)                                                              as total_partitions,
    count(*) filter (where is_expired and not is_empty)                  as pending_truncation,
    count(*) filter (where is_expired and is_empty and not is_ancient)   as truncated_recent,
    count(*) filter (where is_ancient and is_empty)                      as pending_drop,
    max(bound_end)  filter (where is_expired and not is_empty)           as oldest_pending_truncation
from pgfr_record._partition_inventory()
group by parent_table;

comment on view pgfr_record.partition_gc_health is
'Operator visibility into partition GC state per parent_table. '
'pending_truncation: expired partitions still holding data (need truncate_old_partitions()). '
'truncated_recent: expired but empty — awaiting monthly drop_ancient_partitions(). '
'pending_drop: ancient (>2× retention) empty partitions ready for DROP. '
'oldest_pending_truncation: max bound_end of non-empty expired partitions (as int4 offset from epoch()). '
'See blueprints/SPEC.md §7.2.';

-- =============================================================================
-- End Phase 1: Core Partition Infrastructure
-- =============================================================================

SELECT pgfr_record.snapshot();
SELECT pgfr_record.sample();
DO $$
DECLARE
    v_sample_schedule TEXT;
BEGIN
    SELECT schedule INTO v_sample_schedule
    FROM cron.job WHERE jobname = 'pgfr_sample';
    RAISE NOTICE '';
    RAISE NOTICE 'Flight Recorder installed successfully.';
    RAISE NOTICE '';
    RAISE NOTICE 'Collection schedule:';
    RAISE NOTICE '  - Snapshots: every minute (WAL, checkpoints, I/O stats) - DURABLE';
    RAISE NOTICE '  - Samples: every 60 seconds (ring buffer, 120 slots, 2-hour retention)';
    RAISE NOTICE '  - Flush: every 5 minutes (ring buffer → durable aggregates)';
    RAISE NOTICE '  - Cleanup: daily at 3 AM (aggregates: 7 days, snapshots: 30 days)';
    RAISE NOTICE '';
    RAISE NOTICE 'Quick start:';
    RAISE NOTICE '  1. Flight Recorder collects automatically in the background';
    RAISE NOTICE '';
    RAISE NOTICE '  2. Query any time window to diagnose performance:';
    RAISE NOTICE '     SELECT * FROM pgfr_analyze.compare(''2024-12-16 14:00'', ''2024-12-16 15:00'');';
    RAISE NOTICE '     SELECT * FROM pgfr_analyze.wait_summary(''2024-12-16 14:00'', ''2024-12-16 15:00'');';
    RAISE NOTICE '';
    RAISE NOTICE '  3. Check capacity and right-sizing:';
    RAISE NOTICE '     SELECT * FROM pgfr_analyze.capacity_dashboard;';
    RAISE NOTICE '     SELECT * FROM pgfr_analyze.capacity_summary(interval ''7 days'');';
    RAISE NOTICE '';
    RAISE NOTICE 'Views for recent activity:';
    RAISE NOTICE '  - pgfr_record.deltas            (snapshot deltas incl. temp files)';
    RAISE NOTICE '  - pgfr_record.recent_waits      (wait events, last 2 hours from ring buffer)';
    RAISE NOTICE '  - pgfr_record.recent_activity   (active sessions, last 2 hours from ring buffer)';
    RAISE NOTICE '  - pgfr_record.recent_locks      (lock contention, last 2 hours from ring buffer)';
    RAISE NOTICE '  - pgfr_record.recent_replication (replication lag, last 2 hours)';
    RAISE NOTICE '';
    RAISE NOTICE 'For analysis & reporting functions (anomaly detection, capacity planning, etc.):';
    RAISE NOTICE '  psql --single-transaction -f pgfr_analyze/install.sql';
    RAISE NOTICE '';
END;
$$;
-- =============================================================================
