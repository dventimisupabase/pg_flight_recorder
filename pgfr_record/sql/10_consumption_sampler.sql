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
    -- recorder_overhead_fraction in consumption_flows rather than a daily rollup.
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
'Called from _snapshot_v2_trigger() alongside _snapshot_v2() — no separate '
'pg_cron job. See Issue #81.';

-- ---------------------------------------------------------------------------
-- 5. Wire into the existing v2 dual-write trigger.
--    _snapshot_v2_trigger() is CREATE OR REPLACEd here (originally defined in
--    09_phase3_snapshots_v2.sql) to also call the consumption collector. This
--    keeps the new table's concerns in their own file while reusing the
--    existing per-tick trigger rather than registering a new cron job.
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._snapshot_v2_trigger()
returns trigger
language plpgsql as $$
begin
    perform pgfr_record._snapshot_v2(new.id::bigint);
    perform pgfr_record._collect_consumption_snapshot(new.id::bigint);
    return new;
end;
$$;

comment on function pgfr_record._snapshot_v2_trigger() is
'AFTER INSERT trigger on snapshots: dual-writes to snapshots_v2 and aligned '
'child tables, and collects the consumption ledger (consumption_snapshots_v2). '
'Non-invasive integration with existing snapshot() function. See Issue #81.';

-- ---------------------------------------------------------------------------
-- 6. consumption_flows — reset-guarded differencing view.
--    Flows (per second) and efficiency ratios, derived from consecutive raw
--    rows per datname. wal_bytes_delta uses the LSN odometer directly (always
--    valid on a primary); every other delta goes through
--    _reset_guarded_delta(), grouped by the reset-sentinel of its source view
--    (db_stats_reset for pg_stat_database-sourced lanes, wal_stats_reset for
--    pg_stat_wal, ckpt_stats_reset for bgwriter/checkpointer). pg_stat_io has
--    no exposed reset sentinel; a reset there still shows up as a regression
--    against the prior tick, which _reset_guarded_delta() also catches.
-- ---------------------------------------------------------------------------
create or replace view pgfr_record.consumption_flows as
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
),
deltas as (
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
    from pairs
)
select
    sample_ts, captured_at, pg_version, datname, interval_seconds,

    -- Flows (per second)
    case when interval_seconds > 0 then (blks_hit_delta + blks_read_delta) / interval_seconds end as logical_blocks_per_s,
    case when interval_seconds > 0 then coalesce(io_reads_total_delta, blks_read_delta) / interval_seconds end as physical_read_blocks_per_s,
    case when interval_seconds > 0 then io_writes_total_delta / interval_seconds end as physical_write_blocks_per_s,
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
from deltas;

comment on view pgfr_record.consumption_flows is
'Reset-guarded flow rates and efficiency ratios derived from consecutive '
'consumption_snapshots_v2 rows. wal_bytes_per_s uses the wal_lsn odometer '
'(ledger of record, valid across a pg_stat_reset()); every other flow/ratio is '
'built on pgfr_record._reset_guarded_delta() and is NULL for any interval where '
'its source counters regressed or their stats were reset. See Issue #81.';
