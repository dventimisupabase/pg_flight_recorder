-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

--------------------------------------------------------------------------------
-- consumption sampler: global block/WAL/tuple flow ledger (Issue #81)
--
-- Records the database's cumulative block/WAL/tuple activity counters once per
-- snapshot() tick and derives per-interval flow rates and efficiency ratios via
-- a reset-guarded differencing view. Piggybacks on the existing v2 dual-write
-- trigger (see 09_phase3_snapshots_v2.sql) rather than adding a new pg_cron
-- job: one more per-minute job would add to the cron.job_run_details growth
-- already called out in README.md's "pg_cron run history" section.
--
-- Deliberately narrower than Issue #81 as filed: no hourly/daily rollup tier.
-- This repo has no such tier for any sampler today ("daily" here means daily
-- RANGE partitioning for retention, not pre-aggregation — see
-- blueprints/SPEC.md §7); building one would mean extending
-- _partition_inventory()'s two-tier retention model, a shared-infrastructure
-- change well beyond one sampler. The raw table plus a reset-guarded live
-- flow/ratio view delivers the same numbers on demand.
--------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. pgfr_record._reset_guarded_delta()
--    Generic reusable primitive: the interval between two cumulative-counter
--    readings is valid only if the counter did not regress AND (when a
--    reset-sentinel timestamp is supplied) the sentinel did not change.
--    Returns NULL for invalid or indeterminate intervals rather than a
--    misleading negative or inflated delta. Intended for reuse by future
--    samplers, not just this one.
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._reset_guarded_delta(
    p_curr                  numeric,
    p_prev                  numeric,
    p_reset_sentinel_curr   timestamptz default null,
    p_reset_sentinel_prev   timestamptz default null
)
returns numeric
language sql
immutable
as $$
    select case
        -- No prior reading (first sample, or new column on an old row): indeterminate.
        when p_curr is null or p_prev is null then null
        -- Sentinel comparison only when both sides have one; a NULL prev sentinel
        -- means "not collected then" (additive schema upgrade), not "just reset".
        when p_reset_sentinel_prev is not null
             and p_reset_sentinel_curr is distinct from p_reset_sentinel_prev then null
        -- Belt-and-suspenders: catches resets that a sentinel comparison would
        -- miss (no sentinel column for that source, or a reset within the same
        -- tick as the sentinel read).
        when p_curr < p_prev then null
        else p_curr - p_prev
    end
$$;

comment on function pgfr_record._reset_guarded_delta(numeric, numeric, timestamptz, timestamptz) is
'Generic reset-guarded delta for a cumulative counter: NULL if either reading is '
'missing, if a supplied reset-sentinel changed between readings, or if the counter '
'regressed. Otherwise curr - prev. Reusable across samplers; not tied to any one '
'source view. See Issue #81.';

-- ---------------------------------------------------------------------------
-- 2. consumption_snapshots_v2 — daily RANGE partitioned, no FK
--    One row per snapshot() tick, scoped to current_database() for the
--    per-database lanes and cluster-wide for WAL/io/checkpointer/bgwriter.
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.consumption_snapshots_v2 (
    snapshot_id             bigint      not null,   -- logical ref to snapshots_v2.snapshot_id
    sample_ts               int4        not null,
    captured_at             timestamptz not null,
    pg_version              integer     not null,
    datname                 text        not null,   -- scope label for the per-database lanes below

    -- WAL odometer: ledger of record. Interval bytes = pg_wal_lsn_diff(curr, prev),
    -- always valid on a primary regardless of stats resets (see consumption_flows).
    wal_lsn                 pg_lsn,

    -- Tuple flow + transactions, from pg_stat_database (per-database)
    tup_returned            bigint,
    tup_fetched             bigint,
    tup_inserted            bigint,
    tup_updated             bigint,
    tup_deleted             bigint,
    xact_commit             bigint,
    xact_rollback           bigint,

    -- Logical block demand + timing, from pg_stat_database (per-database)
    blks_hit                bigint,
    blks_read               bigint,
    blk_read_time_ms        double precision,  -- 0 (not NULL) whenever track_io_timing is off
    blk_write_time_ms       double precision,

    -- Temp spill, from pg_stat_database (per-database)
    temp_files              bigint,
    temp_bytes              bigint,

    -- WAL decomposition, from pg_stat_wal (cluster-wide, advisory vs. wal_lsn)
    wal_records             bigint,
    wal_fpi                 bigint,
    wal_bytes               numeric,
    wal_buffers_full        bigint,
    wal_stats_reset         timestamptz,

    -- Physical I/O by agent, from pg_stat_io where object='relation' (PG16+; cluster-wide)
    io_reads_client         bigint,
    io_writes_client        bigint,
    io_extends_client       bigint,
    io_fsyncs_client        bigint,
    io_reads_autovacuum     bigint,
    io_writes_autovacuum    bigint,
    io_writes_checkpointer  bigint,
    io_fsyncs_checkpointer  bigint,
    io_writes_bgwriter      bigint,
    io_reads_total          bigint,
    io_writes_total         bigint,
    io_extends_total        bigint,

    -- Checkpoint pressure: pg_stat_checkpointer (PG17+) / pg_stat_bgwriter (PG15-16)
    ckpt_num_timed          bigint,
    ckpt_num_requested      bigint,
    ckpt_buffers_written    bigint,
    bgw_buffers_clean       bigint,
    bgw_maxwritten_clean    bigint,
    bgw_buffers_alloc       bigint,
    ckpt_stats_reset        timestamptz,

    -- Reset sentinel + scale denominator, from pg_stat_database (per-database)
    db_stats_reset          timestamptz,
    db_size_bytes           bigint,

    -- Self-accounting: pgfr_record's own block footprint (pg_statio_user_tables,
    -- schemaname='pgfr_record'), reset-guarded by db_stats_reset like the rest of
    -- the per-database lanes. Footnote-grade per Issue #81; exposed as
    -- recorder_overhead_fraction in consumption_flows and summed into
    -- consumption_daily_rollups (Issue #83) so it survives past 30 days too.
    recorder_blks_hit       bigint,
    recorder_blks_read      bigint
) partition by range (sample_ts);

create table if not exists pgfr_record.consumption_snapshots_v2_default
    partition of pgfr_record.consumption_snapshots_v2 default;

comment on table pgfr_record.consumption_snapshots_v2 is
'Global block/WAL/tuple flow ledger: one row per snapshot() tick, daily '
'RANGE-partitioned by int4 sample_ts. No FK: snapshot_id is a logical reference '
'to snapshots_v2. Primary-only — the collector no-ops under pg_is_in_recovery(). '
'Per-database lanes (tup_*, blks_*, temp_*, db_*) are scoped to current_database(); '
'WAL/io/checkpointer/bgwriter lanes are cluster-wide. See Issue #81.';

comment on column pgfr_record.consumption_snapshots_v2.wal_lsn is
'pg_current_wal_lsn() at capture time. Authoritative WAL ledger of record: '
'pg_wal_lsn_diff() against the prior row is valid even across a pg_stat_reset() '
'or pg_stat_reset_shared(''wal''). The wal_bytes column (from pg_stat_wal) is '
'advisory decomposition only.';

comment on column pgfr_record.consumption_snapshots_v2.recorder_blks_hit is
'pgfr_record''s own heap+index+toast block hits (pg_statio_user_tables, '
'schemaname=pgfr_record), summed. Feeds recorder_overhead_fraction in '
'consumption_flows: the instrument itemizing its own overhead.';

comment on column pgfr_record.consumption_snapshots_v2.io_reads_total is
'Block read requests issued to the OS (pg_stat_io, object=relation, PG16+), '
'summed across backend types. This is Postgres asking the OS for a block, not '
'confirmed disk I/O: the OS page cache may satisfy the request without ever '
'reaching physical storage, and Postgres has no way to tell which happened. '
'See consumption_flows.os_read_blocks_per_s.';

comment on column pgfr_record.consumption_snapshots_v2.io_writes_total is
'Block write requests issued to the OS, summed across backend types. PG16+ from '
'pg_stat_io; PG15 falls back to bgwriter/checkpointer buffer counters (no '
'pg_stat_io equivalent). Same caveat as io_reads_total: an OS write request, not '
'confirmation the block reached physical storage. See '
'consumption_flows.os_write_blocks_per_s.';

-- ---------------------------------------------------------------------------
-- 3. Pre-create today's + tomorrow's partition (mirrors 09_phase3_snapshots_v2.sql
--    §4 — pre-creating tomorrow's covers cron jobs running at day's end).
-- ---------------------------------------------------------------------------
do $$
begin
    perform pgfr_record._ensure_partition('consumption_snapshots_v2', current_date,
        'snapshot_id, sample_ts desc');
    perform pgfr_record._ensure_partition('consumption_snapshots_v2', current_date + 1,
        'snapshot_id, sample_ts desc');
end $$;

-- ---------------------------------------------------------------------------
-- 4. _collect_consumption_snapshot() — the collector
--    Version handling follows the repo's established convention (see
--    _snapshot_v2() in 09_phase3_snapshots_v2.sql): a single function branches
--    at runtime on pgfr_record._pg_version(), using dynamic EXECUTE for any
--    query touching a column that does not exist on every supported version
--    (column refs are resolved at parse time, so a bare IF/CASE around the
--    query text is not enough). Issue #81 asked for install-time SQL
--    selection instead; this repo's working, tested pattern for the exact
--    same PG16/PG17 divergence is runtime EXECUTE branching, so that's what
--    this collector uses too.
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._collect_consumption_snapshot(p_snapshot_id bigint)
returns void
language plpgsql as $$
declare
    v_sample_ts             int4;
    v_pg_version            integer;
    v_wal_lsn               pg_lsn;
    v_wal_records           bigint;
    v_wal_fpi               bigint;
    v_wal_bytes             numeric;
    v_wal_buffers_full      bigint;
    v_wal_stats_reset       timestamptz;
    v_ckpt_num_timed        bigint;
    v_ckpt_num_requested    bigint;
    v_ckpt_buffers_written  bigint;
    v_bgw_buffers_clean     bigint;
    v_bgw_maxwritten_clean  bigint;
    v_bgw_buffers_alloc     bigint;
    v_ckpt_stats_reset      timestamptz;
    v_io_reads_client       bigint;
    v_io_writes_client      bigint;
    v_io_extends_client     bigint;
    v_io_fsyncs_client      bigint;
    v_io_reads_autovacuum   bigint;
    v_io_writes_autovacuum  bigint;
    v_io_writes_checkpointer bigint;
    v_io_fsyncs_checkpointer bigint;
    v_io_writes_bgwriter    bigint;
    v_io_reads_total        bigint;
    v_io_writes_total       bigint;
    v_io_extends_total      bigint;
    v_db_stats_reset        timestamptz;
    v_prev_db_reset         timestamptz;
    v_prev_wal_reset        timestamptz;
    v_prev_ckpt_reset       timestamptz;
begin
    -- Primary only: pg_current_wal_lsn(), pg_stat_checkpointer, and several
    -- conflict/replication-adjacent views are absent, zero, or misleading on a
    -- hot standby. No-op rather than write misleading rows (Issue #81 scope note).
    if pg_is_in_recovery() then
        return;
    end if;

    v_sample_ts  := extract(epoch from now() - pgfr_record.epoch())::int4;
    v_pg_version := pgfr_record._pg_version();
    v_wal_lsn    := pg_current_wal_lsn();

    select wal_records, wal_fpi, wal_bytes, wal_buffers_full, stats_reset
    into   v_wal_records, v_wal_fpi, v_wal_bytes, v_wal_buffers_full, v_wal_stats_reset
    from pg_stat_wal;

    -- pg_stat_checkpointer added in PG17; PG15/16 keep checkpoint counters on
    -- pg_stat_bgwriter (same split handled the same way in _snapshot_v2()).
    if v_pg_version >= 17 then
        execute $q$
            select num_timed, num_requested, buffers_written, stats_reset
            from pg_stat_checkpointer
        $q$ into v_ckpt_num_timed, v_ckpt_num_requested, v_ckpt_buffers_written, v_ckpt_stats_reset;

        select buffers_clean, maxwritten_clean, buffers_alloc
        into   v_bgw_buffers_clean, v_bgw_maxwritten_clean, v_bgw_buffers_alloc
        from pg_stat_bgwriter;
    else
        select checkpoints_timed, checkpoints_req, buffers_checkpoint,
               buffers_clean, maxwritten_clean, buffers_alloc, stats_reset
        into   v_ckpt_num_timed, v_ckpt_num_requested, v_ckpt_buffers_written,
               v_bgw_buffers_clean, v_bgw_maxwritten_clean, v_bgw_buffers_alloc, v_ckpt_stats_reset
        from pg_stat_bgwriter;
    end if;

    -- pg_stat_io added in PG16; object='relation' isolates real table/index I/O
    -- from other io objects so it doesn't double-count against temp_bytes.
    if v_pg_version >= 16 then
        execute $q$
            select
                sum(reads)   filter (where backend_type = 'client backend'),
                sum(writes)  filter (where backend_type = 'client backend'),
                sum(extends) filter (where backend_type = 'client backend'),
                sum(fsyncs)  filter (where backend_type = 'client backend'),
                sum(reads)   filter (where backend_type = 'autovacuum worker'),
                sum(writes)  filter (where backend_type = 'autovacuum worker'),
                sum(writes)  filter (where backend_type = 'checkpointer'),
                sum(fsyncs)  filter (where backend_type = 'checkpointer'),
                sum(writes)  filter (where backend_type = 'background writer'),
                sum(reads),
                sum(writes),
                sum(extends)
            from pg_stat_io
            where object = 'relation'
        $q$ into
            v_io_reads_client, v_io_writes_client, v_io_extends_client, v_io_fsyncs_client,
            v_io_reads_autovacuum, v_io_writes_autovacuum,
            v_io_writes_checkpointer, v_io_fsyncs_checkpointer,
            v_io_writes_bgwriter,
            v_io_reads_total, v_io_writes_total, v_io_extends_total;
    else
        -- PG15: no pg_stat_io. writes_total falls back to the bgwriter/checkpointer
        -- buffer counters already read above; reads_total has no PG15 equivalent
        -- and stays NULL (Issue #81 §"Version handling").
        v_io_writes_total := v_ckpt_buffers_written + v_bgw_buffers_clean;
    end if;

    -- Discontinuity detection (Issue #101): compare this tick's reset
    -- sentinels against the previous tick's before inserting the new row,
    -- and record one stats_reset event per family that moved. This is the
    -- same censoring condition _reset_guarded_delta() applies at read time
    -- (prev sentinel known, current distinct from it); the event makes the
    -- fact queryable instead of only NULLing the spanned deltas.
    select stats_reset into v_db_stats_reset
    from pg_stat_database where datname = current_database();

    select cs.db_stats_reset, cs.wal_stats_reset, cs.ckpt_stats_reset
    into   v_prev_db_reset,   v_prev_wal_reset,   v_prev_ckpt_reset
    from pgfr_record.consumption_snapshots_v2 cs
    where cs.datname = current_database()
    order by cs.sample_ts desc
    limit 1;

    if v_prev_db_reset is not null and v_db_stats_reset is distinct from v_prev_db_reset then
        perform pgfr_record._record_discontinuity('stats_reset', 'pg_stat_database',
            jsonb_build_object('previous', v_prev_db_reset, 'current', v_db_stats_reset,
                               'datname', current_database()));
    end if;
    if v_prev_wal_reset is not null and v_wal_stats_reset is distinct from v_prev_wal_reset then
        perform pgfr_record._record_discontinuity('stats_reset', 'pg_stat_wal',
            jsonb_build_object('previous', v_prev_wal_reset, 'current', v_wal_stats_reset));
    end if;
    if v_prev_ckpt_reset is not null and v_ckpt_stats_reset is distinct from v_prev_ckpt_reset then
        perform pgfr_record._record_discontinuity('stats_reset', 'checkpointer_bgwriter',
            jsonb_build_object('previous', v_prev_ckpt_reset, 'current', v_ckpt_stats_reset));
    end if;

    perform pgfr_record._ensure_partition('consumption_snapshots_v2', current_date,
        'snapshot_id, sample_ts desc');

    insert into pgfr_record.consumption_snapshots_v2 (
        snapshot_id, sample_ts, captured_at, pg_version, datname,
        wal_lsn,
        tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted,
        xact_commit, xact_rollback,
        blks_hit, blks_read, blk_read_time_ms, blk_write_time_ms,
        temp_files, temp_bytes,
        wal_records, wal_fpi, wal_bytes, wal_buffers_full, wal_stats_reset,
        io_reads_client, io_writes_client, io_extends_client, io_fsyncs_client,
        io_reads_autovacuum, io_writes_autovacuum,
        io_writes_checkpointer, io_fsyncs_checkpointer,
        io_writes_bgwriter,
        io_reads_total, io_writes_total, io_extends_total,
        ckpt_num_timed, ckpt_num_requested, ckpt_buffers_written,
        bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc, ckpt_stats_reset,
        db_stats_reset, db_size_bytes,
        recorder_blks_hit, recorder_blks_read
    )
    select
        p_snapshot_id, v_sample_ts, now(), v_pg_version, d.datname,
        v_wal_lsn,
        d.tup_returned, d.tup_fetched, d.tup_inserted, d.tup_updated, d.tup_deleted,
        d.xact_commit, d.xact_rollback,
        d.blks_hit, d.blks_read, d.blk_read_time, d.blk_write_time,
        d.temp_files, d.temp_bytes,
        v_wal_records, v_wal_fpi, v_wal_bytes, v_wal_buffers_full, v_wal_stats_reset,
        v_io_reads_client, v_io_writes_client, v_io_extends_client, v_io_fsyncs_client,
        v_io_reads_autovacuum, v_io_writes_autovacuum,
        v_io_writes_checkpointer, v_io_fsyncs_checkpointer,
        v_io_writes_bgwriter,
        v_io_reads_total, v_io_writes_total, v_io_extends_total,
        v_ckpt_num_timed, v_ckpt_num_requested, v_ckpt_buffers_written,
        v_bgw_buffers_clean, v_bgw_maxwritten_clean, v_bgw_buffers_alloc, v_ckpt_stats_reset,
        d.stats_reset, pg_database_size(d.datname),
        rt.recorder_blks_hit, rt.recorder_blks_read
    from pg_stat_database d
    cross join (
        select
            coalesce(sum(heap_blks_hit),  0) + coalesce(sum(idx_blks_hit),  0)
                + coalesce(sum(toast_blks_hit),  0) + coalesce(sum(tidx_blks_hit),  0)  as recorder_blks_hit,
            coalesce(sum(heap_blks_read), 0) + coalesce(sum(idx_blks_read), 0)
                + coalesce(sum(toast_blks_read), 0) + coalesce(sum(tidx_blks_read), 0)  as recorder_blks_read
        from pg_statio_user_tables
        where schemaname = 'pgfr_record'
    ) rt
    where d.datname = current_database();

exception when others then
    raise warning 'pgfr_record: _collect_consumption_snapshot failed [%]: %', sqlstate, sqlerrm;
end;
$$;

comment on function pgfr_record._collect_consumption_snapshot(bigint) is
'Consumption ledger collector: inserts one row into consumption_snapshots_v2 per '
'tick. No-ops under pg_is_in_recovery() (primary only). Non-fatal on failure '
'(wrapped in EXCEPTION, emits WARNING) so it never blocks the rest of snapshot(). '
'Called directly from snapshot() after its main insert (the dual-write '
'trigger that used to drive it is retired, Issue #73); no separate pg_cron '
'job. See Issue #81.';

-- ---------------------------------------------------------------------------
-- 5. The dual-write trigger wiring that used to live here is retired
--    (Issue #73 PR 2): snapshot() calls _collect_consumption_snapshot()
--    directly after its main insert, and the trigger machinery is dropped in
--    09_phase3_snapshots_v2.sql.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 6. consumption_deltas — reset-guarded per-tick component deltas.
--    Split out as its own view (rather than an inline CTE inside
--    consumption_flows) so both the live per-tick flow view and the daily
--    rollup's SUM()-based aggregation (see consumption_daily_rollups below)
--    share one source of truth for the reset-guard wiring, instead of
--    duplicating it. wal_bytes_delta uses the LSN odometer directly (always
--    valid on a primary); every other delta goes through
--    _reset_guarded_delta(), grouped by the reset-sentinel of its source view
--    (db_stats_reset for pg_stat_database-sourced lanes, wal_stats_reset for
--    pg_stat_wal, ckpt_stats_reset for bgwriter/checkpointer). pg_stat_io has
--    no exposed reset sentinel; a reset there still shows up as a regression
--    against the prior tick, which _reset_guarded_delta() also catches.
-- ---------------------------------------------------------------------------
create or replace view pgfr_record.consumption_deltas as
with pairs as (
    select
        cur.sample_ts, cur.captured_at, cur.pg_version, cur.datname,
        prev.sample_ts as prev_sample_ts,
        cur.wal_lsn, prev.wal_lsn as prev_wal_lsn,
        cur.tup_returned, prev.tup_returned as prev_tup_returned,
        cur.tup_fetched, prev.tup_fetched as prev_tup_fetched,
        cur.tup_inserted, prev.tup_inserted as prev_tup_inserted,
        cur.tup_updated, prev.tup_updated as prev_tup_updated,
        cur.tup_deleted, prev.tup_deleted as prev_tup_deleted,
        cur.xact_commit, prev.xact_commit as prev_xact_commit,
        cur.xact_rollback, prev.xact_rollback as prev_xact_rollback,
        cur.blks_hit, prev.blks_hit as prev_blks_hit,
        cur.blks_read, prev.blks_read as prev_blks_read,
        cur.temp_bytes, prev.temp_bytes as prev_temp_bytes,
        cur.db_stats_reset, prev.db_stats_reset as prev_db_stats_reset,
        cur.recorder_blks_hit, prev.recorder_blks_hit as prev_recorder_blks_hit,
        cur.recorder_blks_read, prev.recorder_blks_read as prev_recorder_blks_read,
        cur.wal_records, prev.wal_records as prev_wal_records,
        cur.wal_fpi, prev.wal_fpi as prev_wal_fpi,
        cur.wal_bytes, prev.wal_bytes as prev_wal_bytes,
        cur.wal_stats_reset, prev.wal_stats_reset as prev_wal_stats_reset,
        cur.ckpt_num_timed, prev.ckpt_num_timed as prev_ckpt_num_timed,
        cur.ckpt_num_requested, prev.ckpt_num_requested as prev_ckpt_num_requested,
        cur.ckpt_stats_reset, prev.ckpt_stats_reset as prev_ckpt_stats_reset,
        cur.io_reads_client, prev.io_reads_client as prev_io_reads_client,
        cur.io_writes_client, prev.io_writes_client as prev_io_writes_client,
        cur.io_writes_autovacuum, prev.io_writes_autovacuum as prev_io_writes_autovacuum,
        cur.io_writes_checkpointer, prev.io_writes_checkpointer as prev_io_writes_checkpointer,
        cur.io_writes_bgwriter, prev.io_writes_bgwriter as prev_io_writes_bgwriter,
        cur.io_reads_total, prev.io_reads_total as prev_io_reads_total,
        cur.io_writes_total, prev.io_writes_total as prev_io_writes_total
    from pgfr_record.consumption_snapshots_v2 cur
    left join pgfr_record.consumption_snapshots_v2 prev
           on prev.datname = cur.datname
          and prev.sample_ts = (
                select max(p.sample_ts)
                from pgfr_record.consumption_snapshots_v2 p
                where p.datname = cur.datname
                  and p.sample_ts < cur.sample_ts
              )
)
select
    sample_ts, captured_at, pg_version, datname,
    (sample_ts - prev_sample_ts) as interval_seconds,

    -- WAL ledger of record: LSN diff, not stats-reset-guarded (monotonic on
    -- a primary). Defensive GREATEST(0, ...) floors any unexpected regression.
    case when prev_wal_lsn is null then null
         else greatest(0, pg_wal_lsn_diff(wal_lsn, prev_wal_lsn))
    end as wal_bytes_delta,

    pgfr_record._reset_guarded_delta(tup_returned, prev_tup_returned, db_stats_reset, prev_db_stats_reset) as tup_returned_delta,
    pgfr_record._reset_guarded_delta(tup_inserted, prev_tup_inserted, db_stats_reset, prev_db_stats_reset)
        + pgfr_record._reset_guarded_delta(tup_updated, prev_tup_updated, db_stats_reset, prev_db_stats_reset)
        + pgfr_record._reset_guarded_delta(tup_deleted, prev_tup_deleted, db_stats_reset, prev_db_stats_reset) as tup_mutated_delta,
    pgfr_record._reset_guarded_delta(xact_commit, prev_xact_commit, db_stats_reset, prev_db_stats_reset) as xact_commit_delta,
    pgfr_record._reset_guarded_delta(xact_rollback, prev_xact_rollback, db_stats_reset, prev_db_stats_reset) as xact_rollback_delta,
    pgfr_record._reset_guarded_delta(blks_hit, prev_blks_hit, db_stats_reset, prev_db_stats_reset) as blks_hit_delta,
    pgfr_record._reset_guarded_delta(blks_read, prev_blks_read, db_stats_reset, prev_db_stats_reset) as blks_read_delta,
    pgfr_record._reset_guarded_delta(temp_bytes, prev_temp_bytes, db_stats_reset, prev_db_stats_reset) as temp_bytes_delta,
    pgfr_record._reset_guarded_delta(recorder_blks_hit, prev_recorder_blks_hit, db_stats_reset, prev_db_stats_reset) as recorder_blks_hit_delta,
    pgfr_record._reset_guarded_delta(recorder_blks_read, prev_recorder_blks_read, db_stats_reset, prev_db_stats_reset) as recorder_blks_read_delta,

    pgfr_record._reset_guarded_delta(wal_records, prev_wal_records, wal_stats_reset, prev_wal_stats_reset) as wal_records_delta,
    pgfr_record._reset_guarded_delta(wal_fpi, prev_wal_fpi, wal_stats_reset, prev_wal_stats_reset) as wal_fpi_delta,
    pgfr_record._reset_guarded_delta(wal_bytes, prev_wal_bytes, wal_stats_reset, prev_wal_stats_reset) as wal_bytes_advisory_delta,

    pgfr_record._reset_guarded_delta(ckpt_num_timed, prev_ckpt_num_timed, ckpt_stats_reset, prev_ckpt_stats_reset) as ckpt_num_timed_delta,
    pgfr_record._reset_guarded_delta(ckpt_num_requested, prev_ckpt_num_requested, ckpt_stats_reset, prev_ckpt_stats_reset) as ckpt_num_requested_delta,

    -- pg_stat_io has no exposed reset sentinel; regression-only guard (NULL sentinels).
    pgfr_record._reset_guarded_delta(io_reads_client, prev_io_reads_client) as io_reads_client_delta,
    pgfr_record._reset_guarded_delta(io_writes_client, prev_io_writes_client) as io_writes_client_delta,
    pgfr_record._reset_guarded_delta(io_writes_autovacuum, prev_io_writes_autovacuum) as io_writes_autovacuum_delta,
    pgfr_record._reset_guarded_delta(io_writes_checkpointer, prev_io_writes_checkpointer) as io_writes_checkpointer_delta,
    pgfr_record._reset_guarded_delta(io_writes_bgwriter, prev_io_writes_bgwriter) as io_writes_bgwriter_delta,
    pgfr_record._reset_guarded_delta(io_reads_total, prev_io_reads_total) as io_reads_total_delta,
    pgfr_record._reset_guarded_delta(io_writes_total, prev_io_writes_total) as io_writes_total_delta
from pairs;

comment on view pgfr_record.consumption_deltas is
'Reset-guarded per-tick component deltas for the consumption ledger -- shared '
'base for consumption_flows (live per-tick ratios) and '
'consumption_daily_rollups (SUM()-based daily aggregation via '
'_rollup_consumption_daily(); SUM() skips NULLs, so a reset-invalidated tick '
'is excluded from a day''s sum automatically). See Issue #81, #83.';

comment on column pgfr_record.consumption_deltas.sample_ts is
'[dimension] [epoch-seconds] Seconds since pgfr_record.epoch() for the current '
'(later) snapshot of the differenced pair; the view''s time axis.';

comment on column pgfr_record.consumption_deltas.captured_at is
'[dimension] [timestamp] Wall-clock capture time of the current (later) snapshot '
'of the differenced pair.';

comment on column pgfr_record.consumption_deltas.pg_version is
'[dimension] [bigint] PostgreSQL major version at capture time. Determines which '
'lanes could be collected: pg_stat_io needs PG16+, pg_stat_checkpointer PG17+.';

comment on column pgfr_record.consumption_deltas.datname is
'[dimension] [text] Database the per-database lanes are scoped to (always '
'current_database(); the WAL, io, and checkpointer lanes are cluster-wide).';

comment on column pgfr_record.consumption_deltas.interval_seconds is
'[derived] [seconds] Elapsed wall time between the two snapshots being '
'differenced (this row''s sample_ts minus the prior row''s, per datname); NULL '
'when no prior snapshot exists.';

comment on column pgfr_record.consumption_deltas.wal_bytes_delta is
'[counter-delta] [bytes] WAL bytes generated over the interval, from '
'pg_wal_lsn_diff() on the wal_lsn odometer: the ledger of record, valid even '
'across a pg_stat_reset(). Floored at 0 by GREATEST(); NULL only when no prior '
'snapshot exists.';

comment on column pgfr_record.consumption_deltas.tup_returned_delta is
'[counter-delta] [count] Rows returned by scans over the interval '
'(pg_stat_database.tup_returned, reset-guarded by db_stats_reset); NULL when the '
'interval spans a stats reset or counter regression.';

comment on column pgfr_record.consumption_deltas.tup_mutated_delta is
'[counter-delta] [count] Rows inserted + updated + deleted over the interval '
'(sum of three reset-guarded pg_stat_database deltas); NULL if any component '
'spans a stats reset or counter regression.';

comment on column pgfr_record.consumption_deltas.xact_commit_delta is
'[counter-delta] [count] Transactions committed over the interval '
'(pg_stat_database.xact_commit, reset-guarded by db_stats_reset); NULL when the '
'interval spans a stats reset or counter regression.';

comment on column pgfr_record.consumption_deltas.xact_rollback_delta is
'[counter-delta] [count] Transactions rolled back over the interval '
'(pg_stat_database.xact_rollback, reset-guarded by db_stats_reset); NULL when '
'the interval spans a stats reset or counter regression.';

comment on column pgfr_record.consumption_deltas.blks_hit_delta is
'[counter-delta] [blocks] Buffer-pool hits over the interval '
'(pg_stat_database.blks_hit, reset-guarded by db_stats_reset); NULL when the '
'interval spans a stats reset or counter regression.';

comment on column pgfr_record.consumption_deltas.blks_read_delta is
'[counter-delta] [blocks] Block read requests issued to the OS over the interval '
'(pg_stat_database.blks_read, reset-guarded by db_stats_reset): buffer-pool '
'misses, not confirmed disk I/O. NULL when the interval spans a stats reset or '
'counter regression.';

comment on column pgfr_record.consumption_deltas.temp_bytes_delta is
'[counter-delta] [bytes] Temp-file bytes spilled over the interval '
'(pg_stat_database.temp_bytes, reset-guarded by db_stats_reset); NULL when the '
'interval spans a stats reset or counter regression.';

comment on column pgfr_record.consumption_deltas.recorder_blks_hit_delta is
'[counter-delta] [blocks] Buffer-pool hits against pgfr_record''s own tables and '
'indexes over the interval (self-accounting, reset-guarded by db_stats_reset); '
'a numerator component of consumption_flows.recorder_overhead_fraction.';

comment on column pgfr_record.consumption_deltas.recorder_blks_read_delta is
'[counter-delta] [blocks] Block read requests to the OS for pgfr_record''s own '
'tables and indexes over the interval (self-accounting, reset-guarded by '
'db_stats_reset); a numerator component of '
'consumption_flows.recorder_overhead_fraction.';

comment on column pgfr_record.consumption_deltas.wal_records_delta is
'[counter-delta] [count] WAL records written over the interval '
'(pg_stat_wal.wal_records, cluster-wide, reset-guarded by wal_stats_reset); NULL '
'when the interval spans a stats reset or counter regression.';

comment on column pgfr_record.consumption_deltas.wal_fpi_delta is
'[counter-delta] [count] Full-page images written to WAL over the interval '
'(pg_stat_wal.wal_fpi, cluster-wide, reset-guarded by wal_stats_reset); NULL '
'when the interval spans a stats reset or counter regression.';

comment on column pgfr_record.consumption_deltas.wal_bytes_advisory_delta is
'[counter-delta] [bytes] WAL bytes over the interval per pg_stat_wal.wal_bytes '
'(reset-guarded by wal_stats_reset): advisory decomposition only; '
'wal_bytes_delta from the LSN odometer is the ledger of record. NULL when the '
'interval spans a stats reset or counter regression.';

comment on column pgfr_record.consumption_deltas.ckpt_num_timed_delta is
'[counter-delta] [count] Scheduled (timed) checkpoints over the interval '
'(pg_stat_checkpointer.num_timed on PG17+, pg_stat_bgwriter.checkpoints_timed '
'on PG15/16; reset-guarded by ckpt_stats_reset); NULL when the interval spans a '
'stats reset or counter regression.';

comment on column pgfr_record.consumption_deltas.ckpt_num_requested_delta is
'[counter-delta] [count] Requested (forced) checkpoints over the interval '
'(pg_stat_checkpointer.num_requested on PG17+, pg_stat_bgwriter.checkpoints_req '
'on PG15/16; reset-guarded by ckpt_stats_reset); NULL when the interval spans a '
'stats reset or counter regression.';

comment on column pgfr_record.consumption_deltas.io_reads_client_delta is
'[counter-delta] [blocks] Block read requests to the OS by client backends over '
'the interval (pg_stat_io, object=relation, PG16+; NULL on PG15). pg_stat_io '
'exposes no reset sentinel, so the guard is regression-only: a reset appears as '
'a counter regression and the delta is NULL.';

comment on column pgfr_record.consumption_deltas.io_writes_client_delta is
'[counter-delta] [blocks] Block write requests to the OS by client backends over '
'the interval (pg_stat_io, object=relation, PG16+; NULL on PG15); regression-only '
'guard, see io_reads_client_delta.';

comment on column pgfr_record.consumption_deltas.io_writes_autovacuum_delta is
'[counter-delta] [blocks] Block write requests to the OS by autovacuum workers '
'over the interval (pg_stat_io, object=relation, PG16+; NULL on PG15); '
'regression-only guard, see io_reads_client_delta.';

comment on column pgfr_record.consumption_deltas.io_writes_checkpointer_delta is
'[counter-delta] [blocks] Block write requests to the OS by the checkpointer '
'over the interval (pg_stat_io, object=relation, PG16+; NULL on PG15); '
'regression-only guard, see io_reads_client_delta.';

comment on column pgfr_record.consumption_deltas.io_writes_bgwriter_delta is
'[counter-delta] [blocks] Block write requests to the OS by the background '
'writer over the interval (pg_stat_io, object=relation, PG16+; NULL on PG15); '
'regression-only guard, see io_reads_client_delta.';

comment on column pgfr_record.consumption_deltas.io_reads_total_delta is
'[counter-delta] [blocks] Block read requests to the OS over the interval, '
'summed across backend types (pg_stat_io, object=relation, PG16+; NULL on PG15, '
'which has no equivalent). Not confirmed disk I/O; regression-only guard.';

comment on column pgfr_record.consumption_deltas.io_writes_total_delta is
'[counter-delta] [blocks] Block write requests to the OS over the interval, '
'summed across backend types (pg_stat_io, object=relation, PG16+; on PG15 falls '
'back to checkpointer + bgwriter buffer counters). Not confirmed disk I/O; '
'regression-only guard.';

-- ---------------------------------------------------------------------------
-- 7. consumption_flows — flow rates and efficiency ratios derived from
--    consumption_deltas. Purely a reshaping of consumption_deltas into rates
--    and ratios; the reset-guard wiring itself lives there, not here.
-- ---------------------------------------------------------------------------
create or replace view pgfr_record.consumption_flows as
select
    sample_ts, captured_at, pg_version, datname, interval_seconds,

    -- Flows (per second)
    case when interval_seconds > 0 then (blks_hit_delta + blks_read_delta) / interval_seconds end as block_demand_per_s,
    case when interval_seconds > 0 then coalesce(io_reads_total_delta, blks_read_delta) / interval_seconds end as os_read_blocks_per_s,
    case when interval_seconds > 0 then io_writes_total_delta / interval_seconds end as os_write_blocks_per_s,
    case when interval_seconds > 0 then wal_bytes_delta / interval_seconds end as wal_bytes_per_s,
    case when interval_seconds > 0 then tup_returned_delta / interval_seconds end as rows_returned_per_s,
    case when interval_seconds > 0 then tup_mutated_delta / interval_seconds end as rows_mutated_per_s,
    case when interval_seconds > 0 then (xact_commit_delta + xact_rollback_delta) / interval_seconds end as xact_per_s,
    case when interval_seconds > 0 then temp_bytes_delta / interval_seconds end as temp_bytes_per_s,

    -- Decompositions
    blks_hit_delta / nullif(blks_hit_delta + blks_read_delta, 0) as cache_hit_fraction,
    (wal_fpi_delta * current_setting('block_size')::numeric) / nullif(wal_bytes_advisory_delta, 0) as fpi_fraction,
    ckpt_num_requested_delta / nullif(ckpt_num_timed_delta + ckpt_num_requested_delta, 0) as ckpt_requested_fraction,
    io_writes_client_delta / nullif(io_writes_total_delta, 0) as write_share_client,
    io_writes_autovacuum_delta / nullif(io_writes_total_delta, 0) as write_share_autovacuum,
    io_writes_checkpointer_delta / nullif(io_writes_total_delta, 0) as write_share_checkpointer,
    io_writes_bgwriter_delta / nullif(io_writes_total_delta, 0) as write_share_bgwriter,

    -- Ratios (efficiency figures of merit; hardware divided out)
    (blks_hit_delta + blks_read_delta) / nullif(tup_returned_delta, 0) as blocks_per_row_returned,
    wal_bytes_delta / nullif(tup_mutated_delta, 0) as wal_bytes_per_row_mutated,
    temp_bytes_delta / nullif(xact_commit_delta, 0) as temp_bytes_per_xact,

    -- Self-accounting (footnote-grade; see Issue #81 "Self-accounting")
    (recorder_blks_hit_delta + recorder_blks_read_delta) / nullif(blks_hit_delta + blks_read_delta, 0) as recorder_overhead_fraction
from pgfr_record.consumption_deltas;

comment on view pgfr_record.consumption_flows is
'Flow rates and efficiency ratios computed from pgfr_record.consumption_deltas. '
'wal_bytes_per_s uses the wal_lsn odometer (ledger of record, valid across a '
'pg_stat_reset()); every other flow/ratio is NULL for any interval where its '
'source counters regressed or their stats were reset (see consumption_deltas '
'and pgfr_record._reset_guarded_delta()). See Issue #81. Deliberately avoids '
'"logical"/"physical" I/O labels -- see os_read_blocks_per_s and '
'os_write_blocks_per_s below for why.';

comment on column pgfr_record.consumption_flows.sample_ts is
'[dimension] [epoch-seconds] Seconds since pgfr_record.epoch() for the tick that '
'closed the interval; inherited from consumption_deltas.';

comment on column pgfr_record.consumption_flows.captured_at is
'[dimension] [timestamp] Wall-clock capture time of the tick that closed the '
'interval; inherited from consumption_deltas.';

comment on column pgfr_record.consumption_flows.pg_version is
'[dimension] [bigint] PostgreSQL major version at capture time. Determines which '
'lanes could be collected: pg_stat_io needs PG16+, pg_stat_checkpointer PG17+.';

comment on column pgfr_record.consumption_flows.datname is
'[dimension] [text] Database the per-database lanes are scoped to (always '
'current_database(); the WAL, io, and checkpointer lanes are cluster-wide).';

comment on column pgfr_record.consumption_flows.interval_seconds is
'[derived] [seconds] Elapsed wall time between the two snapshots being '
'differenced; the denominator of every per-second rate in this view. NULL when '
'no prior snapshot exists.';

comment on column pgfr_record.consumption_flows.block_demand_per_s is
'[counter-delta] [blocks/s] [interval-mean] Total block accesses through the '
'buffer pool per second (blks_hit + blks_read), hit or miss. Not "logical" as '
'opposed to some other kind -- just the total demand the executor placed on the '
'buffer pool, independent of how each access was satisfied. Mean rate over the '
'tick interval, never instantaneous.';

comment on column pgfr_record.consumption_flows.os_read_blocks_per_s is
'[counter-delta] [blocks/s] [interval-mean] Block read requests issued to the OS '
'per second (buffer pool misses): from pg_stat_io (object=relation, PG16+) or '
'pg_stat_database.blks_read as fallback. NOT confirmed disk I/O -- Postgres '
'calls the OS for these blocks and neither knows nor cares whether the OS '
'serves the request from its own page cache or from physical storage. Calling '
'this "physical" I/O (as Issue #81 originally did) overstates what is actually '
'measurable from inside Postgres. Mean rate over the tick interval.';

comment on column pgfr_record.consumption_flows.os_write_blocks_per_s is
'[counter-delta] [blocks/s] [interval-mean] Block write requests issued to the '
'OS per second (from pg_stat_io, PG16+; NULL on PG15). Same caveat as '
'os_read_blocks_per_s: this is Postgres asking the OS to write a block, not '
'confirmation the block reached physical storage -- the OS may hold it in page '
'cache until its own writeback policy flushes it. Mean rate over the tick '
'interval.';

comment on column pgfr_record.consumption_flows.wal_bytes_per_s is
'[counter-delta] [bytes/s] [interval-mean] WAL bytes per second from the wal_lsn '
'odometer (wal_bytes_delta / interval_seconds): mean rate over the tick '
'interval, not instantaneous. Ledger of record, valid across stats resets; NULL '
'only when no prior snapshot exists.';

comment on column pgfr_record.consumption_flows.rows_returned_per_s is
'[counter-delta] [count/s] [interval-mean] Rows returned by scans per second '
'(tup_returned_delta / interval_seconds): mean rate over the tick interval. '
'NULL when the underlying delta was censored by a stats reset.';

comment on column pgfr_record.consumption_flows.rows_mutated_per_s is
'[counter-delta] [count/s] [interval-mean] Rows inserted + updated + deleted per '
'second (tup_mutated_delta / interval_seconds): mean rate over the tick '
'interval. NULL when the underlying delta was censored by a stats reset.';

comment on column pgfr_record.consumption_flows.xact_per_s is
'[counter-delta] [count/s] [interval-mean] Transactions per second, commits plus '
'rollbacks ((xact_commit_delta + xact_rollback_delta) / interval_seconds): mean '
'rate over the tick interval. NULL when either delta was censored by a stats '
'reset.';

comment on column pgfr_record.consumption_flows.temp_bytes_per_s is
'[counter-delta] [bytes/s] [interval-mean] Temp-file bytes spilled per second '
'(temp_bytes_delta / interval_seconds): mean rate over the tick interval. NULL '
'when the underlying delta was censored by a stats reset.';

comment on column pgfr_record.consumption_flows.cache_hit_fraction is
'[derived] [fraction] Share of buffer-pool block demand satisfied from shared '
'buffers, 0 to 1: blks_hit_delta over (blks_hit_delta + blks_read_delta). NULL '
'when the denominator is zero or a delta was reset-censored.';

comment on column pgfr_record.consumption_flows.fpi_fraction is
'[derived] [fraction] Approximate share of WAL volume consumed by full-page '
'images, 0 to 1: wal_fpi_delta times block_size over wal_bytes_advisory_delta '
'(the advisory pg_stat_wal byte count, not the LSN odometer). NULL when the '
'denominator is zero or a delta was reset-censored.';

comment on column pgfr_record.consumption_flows.ckpt_requested_fraction is
'[derived] [fraction] Share of checkpoints that were requested (forced) rather '
'than scheduled, 0 to 1: ckpt_num_requested_delta over (ckpt_num_timed_delta + '
'ckpt_num_requested_delta). NULL when no checkpoints occurred in the interval '
'or a delta was reset-censored.';

comment on column pgfr_record.consumption_flows.write_share_client is
'[derived] [fraction] Share of OS block write requests issued by client '
'backends, 0 to 1: io_writes_client_delta over io_writes_total_delta '
'(pg_stat_io, PG16+; NULL on PG15 or when the denominator is zero).';

comment on column pgfr_record.consumption_flows.write_share_autovacuum is
'[derived] [fraction] Share of OS block write requests issued by autovacuum '
'workers, 0 to 1: io_writes_autovacuum_delta over io_writes_total_delta '
'(pg_stat_io, PG16+; NULL on PG15 or when the denominator is zero).';

comment on column pgfr_record.consumption_flows.write_share_checkpointer is
'[derived] [fraction] Share of OS block write requests issued by the '
'checkpointer, 0 to 1: io_writes_checkpointer_delta over io_writes_total_delta '
'(pg_stat_io, PG16+; NULL on PG15 or when the denominator is zero).';

comment on column pgfr_record.consumption_flows.write_share_bgwriter is
'[derived] [fraction] Share of OS block write requests issued by the background '
'writer, 0 to 1: io_writes_bgwriter_delta over io_writes_total_delta '
'(pg_stat_io, PG16+; NULL on PG15 or when the denominator is zero).';

comment on column pgfr_record.consumption_flows.blocks_per_row_returned is
'[derived] [blocks/row] Buffer-pool block demand per row returned: '
'(blks_hit_delta + blks_read_delta) over tup_returned_delta. Efficiency figure '
'of merit with hardware divided out. NULL when no rows were returned or a delta '
'was reset-censored.';

comment on column pgfr_record.consumption_flows.wal_bytes_per_row_mutated is
'[derived] [bytes/row] WAL bytes per row mutated: wal_bytes_delta (LSN odometer) '
'over tup_mutated_delta (rows inserted + updated + deleted). NULL when no rows '
'were mutated or the denominator delta was reset-censored.';

comment on column pgfr_record.consumption_flows.temp_bytes_per_xact is
'[derived] [bytes/xact] Temp-file bytes spilled per committed transaction: '
'temp_bytes_delta over xact_commit_delta (commits only, rollbacks excluded). '
'NULL when no commits occurred or a delta was reset-censored.';

comment on column pgfr_record.consumption_flows.recorder_overhead_fraction is
'[derived] [fraction] The recorder''s own share of total buffer-pool block '
'demand, 0 to 1: (recorder_blks_hit_delta + recorder_blks_read_delta) over '
'(blks_hit_delta + blks_read_delta). The instrument itemizing its own observer '
'effect; footnote-grade. NULL when the denominator is zero or a delta was '
'reset-censored.';

--------------------------------------------------------------------------------
-- consumption_daily_rollups (Issue #83 prerequisite): a daily-grain durable
-- rollup of the consumption ledger, so trend analysis over windows longer
-- than consumption_snapshots_v2's 30-day retention (Issue #83 wants 28d/90d
-- Theil-Sen windows) has something to read once the raw ticks age out.
--
-- Deliberately NOT partitioned and NOT subject to any retention/cleanup: at
-- one row per calendar day per datname, this table is tiny by construction
-- (a decade is ~3,650 rows) -- the same reasoning Issue #83 itself gives for
-- keeping trend rows indefinitely applies here first. The partition-drop
-- machinery elsewhere in this schema solves a bloat problem that cannot occur
-- at this row count, so it isn't reused here.
--
-- Stores summed numerator/denominator components, not pre-computed ratios --
-- same Σnum/Σden discipline as the rest of this schema's rollup convention:
-- ratios are reconstructed from sums, never averaged from finer-grained
-- ratios. Scope is exactly Issue #83's metric basket plus the existing
-- recorder_overhead_fraction self-accounting figure (already a real signal in
-- consumption_flows; omitting it here would just be another way to lose it
-- once raw data ages out, the exact failure mode this table exists to avoid).
-- basket_version is NOT stored here: that concept belongs to the eventual
-- trend table (Issue #83's own deliverable), which versions which metrics get
-- trended -- this table just stores facts.
--------------------------------------------------------------------------------

create table if not exists pgfr_record.consumption_daily_rollups (
    rollup_date                 date    not null,
    datname                     text    not null,

    -- Coverage / transparency, not assumed to be a fixed 86400s/day: an
    -- interval is attributed to the calendar day of its END timestamp (the
    -- tick that closed it), so a day with a gap (recorder downtime) or a
    -- partial first/last day naturally has a smaller total_seconds and
    -- valid_tick_count rather than a silently wrong rate.
    total_seconds                integer not null,
    valid_tick_count             integer not null,

    -- pg_stat_database-scoped sums (guarded by db_stats_reset in consumption_deltas)
    blks_hit_sum                 bigint,
    blks_read_sum                 bigint,
    tup_returned_sum              bigint,
    tup_mutated_sum               bigint,
    xact_commit_sum               bigint,
    xact_rollback_sum             bigint,
    temp_bytes_sum                bigint,
    recorder_blks_hit_sum         bigint,
    recorder_blks_read_sum        bigint,

    -- WAL ledger + advisory decomposition (LSN-based sum is not stats-reset-guarded)
    wal_bytes_sum                 numeric,
    wal_fpi_sum                   bigint,
    wal_bytes_advisory_sum        numeric,

    -- Checkpointer/bgwriter-scoped sums (guarded by ckpt_stats_reset)
    ckpt_num_timed_sum            bigint,
    ckpt_num_requested_sum        bigint,

    -- pg_stat_io-scoped sums (PG16+; NULL on PG15, regression-only guarded)
    io_writes_autovacuum_sum      bigint,
    io_writes_total_sum           bigint,

    -- Gauge, not a flow: the day's last observed value, not a sum
    db_size_bytes                 bigint,

    primary key (rollup_date, datname)
);

comment on table pgfr_record.consumption_daily_rollups is
'Daily-grain durable rollup of the consumption ledger: one row per calendar '
'day per datname, populated by _rollup_consumption_daily() from the daily '
'pgfr_cleanup cron job (no separate job). Stores summed components, not '
'ratios -- reconstruct ratios via SUM-of-sums, matching the rest of this '
'schema''s rollup convention. Not partitioned, no retention: at one row/day '
'this table stays tiny indefinitely, so the bloat problem partition-drop '
'exists to solve cannot occur here. See Issue #83.';

comment on column pgfr_record.consumption_daily_rollups.total_seconds is
'Sum of interval_seconds across the day''s valid ticks (from '
'consumption_deltas). Use as the denominator for daily "_per_s" rates instead '
'of assuming 86400 -- a day with a recorder outage or a partial first/last '
'day has a proportionally smaller total_seconds, not a silently wrong rate.';

comment on column pgfr_record.consumption_daily_rollups.valid_tick_count is
'Count of ticks that contributed to this row. A low count relative to the '
'configured sample interval is the same signal Issue #83''s reporting '
'requirements call for making explicit ("14 days required, 6 collected") '
'rather than silently omitting. Counts intervals present, not per-metric '
'validity: a reset-invalidated scope (e.g. a mid-day pg_stat_reset()) can '
'still leave some *_sum columns NULL for a day counted here.';

-- ---------------------------------------------------------------------------
-- _rollup_consumption_daily() — populates consumption_daily_rollups.
-- Idempotent: rolls up every calendar day that has consumption_deltas data
-- but no rollup row yet, up to (and excluding) the current day, so it catches
-- up gaps (e.g. after downtime) rather than only ever handling "yesterday".
-- Never rolls up the current day: a day in progress is never a candidate, so
-- a rollup row always covers a fully-closed day.
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._rollup_consumption_daily()
returns void
language plpgsql as $$
declare
    v_day date;
begin
    for v_day in
        select distinct (pgfr_record.epoch() + d.sample_ts * interval '1 second')::date as day
        from pgfr_record.consumption_deltas d
        where (pgfr_record.epoch() + d.sample_ts * interval '1 second')::date < current_date
          and not exists (
              select 1 from pgfr_record.consumption_daily_rollups r
              where r.rollup_date = (pgfr_record.epoch() + d.sample_ts * interval '1 second')::date
                and r.datname = d.datname
          )
        order by day
    loop
        insert into pgfr_record.consumption_daily_rollups (
            rollup_date, datname, total_seconds, valid_tick_count,
            blks_hit_sum, blks_read_sum,
            tup_returned_sum, tup_mutated_sum,
            xact_commit_sum, xact_rollback_sum,
            temp_bytes_sum,
            recorder_blks_hit_sum, recorder_blks_read_sum,
            wal_bytes_sum, wal_fpi_sum, wal_bytes_advisory_sum,
            ckpt_num_timed_sum, ckpt_num_requested_sum,
            io_writes_autovacuum_sum, io_writes_total_sum,
            db_size_bytes
        )
        select
            v_day, d.datname,
            sum(d.interval_seconds)::integer, count(d.interval_seconds)::integer,
            sum(d.blks_hit_delta), sum(d.blks_read_delta),
            sum(d.tup_returned_delta), sum(d.tup_mutated_delta),
            sum(d.xact_commit_delta), sum(d.xact_rollback_delta),
            sum(d.temp_bytes_delta),
            sum(d.recorder_blks_hit_delta), sum(d.recorder_blks_read_delta),
            sum(d.wal_bytes_delta), sum(d.wal_fpi_delta), sum(d.wal_bytes_advisory_delta),
            sum(d.ckpt_num_timed_delta), sum(d.ckpt_num_requested_delta),
            sum(d.io_writes_autovacuum_delta), sum(d.io_writes_total_delta),
            (
                select s.db_size_bytes
                from pgfr_record.consumption_snapshots_v2 s
                where s.datname = d.datname
                  and (pgfr_record.epoch() + s.sample_ts * interval '1 second')::date = v_day
                order by s.sample_ts desc
                limit 1
            )
        from pgfr_record.consumption_deltas d
        where (pgfr_record.epoch() + d.sample_ts * interval '1 second')::date = v_day
        group by d.datname
        on conflict (rollup_date, datname) do nothing;
    end loop;
exception when others then
    raise warning 'pgfr_record: _rollup_consumption_daily failed: %', sqlerrm;
end;
$$;

comment on function pgfr_record._rollup_consumption_daily() is
'Populates consumption_daily_rollups from consumption_deltas: one row per '
'calendar day per datname, summed components (Σnum/Σden discipline). '
'Idempotent and catch-up capable -- rolls up any day with data but no rollup '
'row yet, up to (excluding) the current day. Called from the daily '
'pgfr_cleanup cron job, not a separate schedule. Non-fatal on failure '
'(wrapped in EXCEPTION, emits WARNING). See Issue #83.';

-- ---------------------------------------------------------------------------
-- consumption_daily_flows — daily-grain sibling of consumption_flows.
-- Reconstructs ratios from consumption_daily_rollups' summed components.
-- Purely mechanical (no judgment, no trend/classification logic) -- the same
-- category as consumption_flows, so it lives here in pgfr_record rather than
-- in pgfr_analyze. Unlike consumption_flows, no self-join against a prior row
-- is needed: consumption_daily_rollups already has one pre-summed row per day.
--
-- Covers Issue #83's full metric basket plus its workload-shape guard
-- indicators; pgfr_analyze's trend engine (Issue #83, in progress) reads this
-- view rather than consumption_daily_rollups directly.
-- ---------------------------------------------------------------------------
create or replace view pgfr_record.consumption_daily_flows as
select
    rollup_date, datname, total_seconds, valid_tick_count,

    -- Specific consumption (headline). Numerators explicitly cast to numeric:
    -- these sums are bigint, and bigint/bigint in Postgres is truncating
    -- integer division, not the continuous division a ratio needs.
    (blks_hit_sum + blks_read_sum)::numeric / nullif(tup_returned_sum, 0) as blocks_per_row_returned,
    wal_bytes_sum / nullif(tup_mutated_sum, 0) as wal_bytes_per_row_mutated,
    temp_bytes_sum::numeric / nullif(xact_commit_sum, 0) as temp_bytes_per_xact,

    -- Amplification / mechanically unambiguous
    (wal_fpi_sum * current_setting('block_size')::numeric) / nullif(wal_bytes_advisory_sum, 0) as fpi_fraction,
    ckpt_num_requested_sum::numeric / nullif(ckpt_num_timed_sum + ckpt_num_requested_sum, 0) as ckpt_requested_fraction,
    xact_rollback_sum::numeric / nullif(xact_commit_sum + xact_rollback_sum, 0) as rollback_fraction,
    io_writes_autovacuum_sum::numeric / nullif(io_writes_total_sum, 0) as autovacuum_write_share,

    -- Substrate (tracked, never called consumption)
    blks_hit_sum::numeric / nullif(blks_hit_sum + blks_read_sum, 0) as cache_hit_fraction,

    -- Workload-shape indicators (guards, not metrics -- see the composition-
    -- drift confound in Issue #83)
    tup_returned_sum::numeric / nullif(tup_mutated_sum, 0) as read_write_tuple_ratio,
    (xact_commit_sum + xact_rollback_sum)::numeric / nullif(total_seconds, 0) as xact_per_s,
    tup_returned_sum::numeric / nullif(xact_commit_sum + xact_rollback_sum, 0) as rows_returned_per_xact,
    tup_mutated_sum::numeric / nullif(xact_commit_sum + xact_rollback_sum, 0) as rows_mutated_per_xact,
    db_size_bytes,

    -- Self-accounting (footnote-grade; see consumption_flows.recorder_overhead_fraction)
    (recorder_blks_hit_sum + recorder_blks_read_sum)::numeric / nullif(blks_hit_sum + blks_read_sum, 0) as recorder_overhead_fraction
from pgfr_record.consumption_daily_rollups;

comment on view pgfr_record.consumption_daily_flows is
'Daily-grain ratios reconstructed from consumption_daily_rollups'' summed '
'components -- the same Σnum/Σden reconstruction consumption_flows does at '
'per-tick grain, one tier up. Covers Issue #83''s metric basket and '
'workload-shape guard indicators. A NULL ratio means its day''s underlying '
'sum was itself NULL (reset-excluded) or the denominator was zero -- both '
'nullif-guarded, never a division error. See Issue #83.';

comment on column pgfr_record.consumption_daily_flows.rollup_date is
'[dimension] [date] Calendar day the rollup covers. An interval is attributed '
'to the day of its end timestamp (the tick that closed it).';

comment on column pgfr_record.consumption_daily_flows.datname is
'[dimension] [text] Database the per-database lanes are scoped to (always '
'current_database(); the WAL, io, and checkpointer lanes are cluster-wide).';

comment on column pgfr_record.consumption_daily_flows.total_seconds is
'[derived] [seconds] Elapsed wall time covered by the day''s valid ticks (sum '
'of consumption_deltas.interval_seconds): the denominator for this view''s '
'per-second rates, not an assumed 86400. A day with recorder downtime or a '
'partial first/last day has proportionally fewer seconds.';

comment on column pgfr_record.consumption_daily_flows.valid_tick_count is
'[derived] [count] Number of delta intervals that contributed to the day''s '
'sums. Counts intervals present, not per-metric validity: a mid-day stats reset '
'can still leave individual ratios NULL for a day counted here. Low values flag '
'partial coverage.';

comment on column pgfr_record.consumption_daily_flows.blocks_per_row_returned is
'[derived] [blocks/row] Buffer-pool block demand per row returned over the day: '
'(blks_hit_sum + blks_read_sum) over tup_returned_sum, reconstructed from the '
'day''s summed components. NULL when the denominator is zero or a component sum '
'was reset-excluded.';

comment on column pgfr_record.consumption_daily_flows.wal_bytes_per_row_mutated is
'[derived] [bytes/row] WAL bytes per row mutated over the day: wal_bytes_sum '
'(LSN odometer) over tup_mutated_sum (rows inserted + updated + deleted). NULL '
'when the denominator is zero or a component sum was reset-excluded.';

comment on column pgfr_record.consumption_daily_flows.temp_bytes_per_xact is
'[derived] [bytes/xact] Temp-file bytes spilled per committed transaction over '
'the day: temp_bytes_sum over xact_commit_sum (commits only, rollbacks '
'excluded). NULL when the denominator is zero or a component sum was '
'reset-excluded.';

comment on column pgfr_record.consumption_daily_flows.fpi_fraction is
'[derived] [fraction] Approximate share of the day''s WAL volume consumed by '
'full-page images, 0 to 1: wal_fpi_sum times block_size over '
'wal_bytes_advisory_sum (the advisory pg_stat_wal byte count). NULL when the '
'denominator is zero or a component sum was reset-excluded.';

comment on column pgfr_record.consumption_daily_flows.ckpt_requested_fraction is
'[derived] [fraction] Share of the day''s checkpoints that were requested '
'(forced) rather than scheduled, 0 to 1: ckpt_num_requested_sum over '
'(ckpt_num_timed_sum + ckpt_num_requested_sum). NULL when no checkpoints '
'occurred or a component sum was reset-excluded.';

comment on column pgfr_record.consumption_daily_flows.rollback_fraction is
'[derived] [fraction] Share of the day''s transactions that rolled back, 0 to '
'1: xact_rollback_sum over (xact_commit_sum + xact_rollback_sum). NULL when the '
'denominator is zero or a component sum was reset-excluded.';

comment on column pgfr_record.consumption_daily_flows.autovacuum_write_share is
'[derived] [fraction] Share of the day''s OS block write requests issued by '
'autovacuum workers, 0 to 1: io_writes_autovacuum_sum over io_writes_total_sum '
'(pg_stat_io, PG16+; NULL on PG15 or when the denominator is zero).';

comment on column pgfr_record.consumption_daily_flows.cache_hit_fraction is
'[derived] [fraction] Share of the day''s buffer-pool block demand satisfied '
'from shared buffers, 0 to 1: blks_hit_sum over (blks_hit_sum + blks_read_sum). '
'NULL when the denominator is zero or a component sum was reset-excluded.';

comment on column pgfr_record.consumption_daily_flows.read_write_tuple_ratio is
'[derived] [ratio] Workload-shape guard, not a consumption metric: '
'tup_returned_sum over tup_mutated_sum for the day. Unbounded (a read-heavy day '
'is far above 1). NULL when no rows were mutated or a component sum was '
'reset-excluded.';

comment on column pgfr_record.consumption_daily_flows.xact_per_s is
'[counter-delta] [count/s] [interval-mean] Transactions per second, commits '
'plus rollbacks: (xact_commit_sum + xact_rollback_sum) over total_seconds. Mean '
'rate over the day''s covered seconds, never instantaneous. NULL when a '
'component sum was reset-excluded.';

comment on column pgfr_record.consumption_daily_flows.rows_returned_per_xact is
'[derived] [rows/xact] Workload-shape guard: rows returned per transaction for '
'the day, tup_returned_sum over (xact_commit_sum + xact_rollback_sum). NULL '
'when the denominator is zero or a component sum was reset-excluded.';

comment on column pgfr_record.consumption_daily_flows.rows_mutated_per_xact is
'[derived] [rows/xact] Workload-shape guard: rows mutated per transaction for '
'the day, tup_mutated_sum over (xact_commit_sum + xact_rollback_sum). NULL when '
'the denominator is zero or a component sum was reset-excluded.';

comment on column pgfr_record.consumption_daily_flows.db_size_bytes is
'[gauge] [bytes] The day''s last observed pg_database_size() for datname, taken '
'from the final snapshot of the day. Exact at that instant, undefined between '
'ticks; a level, not a flow, so it is carried through rather than summed.';

comment on column pgfr_record.consumption_daily_flows.recorder_overhead_fraction is
'[derived] [fraction] The recorder''s own share of the day''s total buffer-pool '
'block demand, 0 to 1: (recorder_blks_hit_sum + recorder_blks_read_sum) over '
'(blks_hit_sum + blks_read_sum). Footnote-grade self-accounting. NULL when the '
'denominator is zero or a component sum was reset-excluded.';
