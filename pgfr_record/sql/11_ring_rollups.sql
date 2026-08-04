-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

--------------------------------------------------------------------------------
-- Ring rollups: durable, bounded-size wait/lock/activity summaries beyond the
-- ring buffer's 2h window.
--
-- The original wait_event_aggregates / lock_aggregates / activity_aggregates
-- (fed by flush_ring_to_aggregates() on its own 5-min cron job) were retired
-- as orphaned dead code in "wave 13" of the ring-buffer overhaul: their cron
-- schedule had been dropped even earlier ("wave 1") without anyone
-- re-wiring it, and pgfr_analyze's readers had already been migrated to read
-- the 2h ring directly as a stopgap. That was erosion across unrelated
-- refactors, not a decision to drop long-term wait/lock/activity visibility.
--
-- This reintroduces the aggregate layer only -- not the full-resolution
-- *_samples_archive tables that were also retired alongside it. Raw
-- long-retention archiving at full sample resolution is the unbounded-growth
-- pattern the rest of this schema's partition/sparse-storage overhaul exists
-- to eliminate; an aggregate table (bounded by distinct dimension values x
-- time buckets, not raw row count) doesn't have that problem.
--
-- Differences from the retired design:
--   - Partition-based retention (RANGE by sample_ts, TRUNCATE/DROP), not
--     cleanup_aggregates()'s DELETE FROM ... WHERE start_time < cutoff on
--     plain heap tables -- the exact bloat pattern this schema's storage
--     overhaul eliminated everywhere else.
--   - Table names end in _archive_v2 so _partition_inventory()'s existing
--     archive-tier cutoff (retention_archive_days, default 7 -- matching the
--     old aggregate_retention_days default) picks them up with no new
--     shared infrastructure. retention_archive_days has had "no active
--     subscriber" since the wave-13 retirement (see its comment in
--     09_phase3_snapshots_v2.sql); these tables are that future subscriber.
--     NOTE: reusing the *_archive_v2 name suffix is what buys this for free;
--     don't read "archive" here as "raw full-resolution archive" -- these
--     are aggregates.
--   - No separate cron job and no persisted flush watermark. Rolled up
--     in-place inside rotate_ring() (08_ring_buffer_v2.sql), right before it
--     TRUNCATEs the slot being rotated out -- the exact, race-free moment
--     that slot's data would otherwise be destroyed. The old watermark
--     (max(end_time) read back out of wait_event_aggregates itself) was a
--     single point of failure; querying "whatever's currently in this slot"
--     has no persisted state to get out of sync.
--   - activity_aggregates grouped by raw query_preview text, an
--     unbounded-cardinality key, and one now redundant with
--     statement_snapshots_v2's real queryid-based stats. The new
--     activity_rollups_archive_v2 groups by backend_type / state / a
--     duration bucket instead: a bounded-cardinality profile of concurrency
--     and long-running-session patterns that statement_snapshots_v2 doesn't
--     cover.
--------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. wait_event_rollups_archive_v2
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.wait_event_rollups_archive_v2 (
    sample_ts        int4        not null,  -- window end, seconds since epoch()
    start_time       timestamptz not null,
    end_time         timestamptz not null,
    backend_type     text        not null,  -- from wait_event_map.state (see comment below)
    wait_event_type  text        not null,
    wait_event       text        not null,
    sample_count     integer     not null,
    total_waiters    bigint      not null,
    avg_waiters      numeric     not null,
    max_waiters      integer     not null,
    pct_of_samples   numeric
) partition by range (sample_ts);

create table if not exists pgfr_record.wait_event_rollups_archive_v2_default
    partition of pgfr_record.wait_event_rollups_archive_v2 default;

comment on table pgfr_record.wait_event_rollups_archive_v2 is
'Durable wait-event summaries, one row per (backend_type, wait_event_type, '
'wait_event) per ring rotation window. Written by _flush_ring_slot_to_rollups() '
'from rotate_ring(), not a separate cron job. Daily RANGE-partitioned by '
'sample_ts; the _archive_v2 name buys retention_archive_days-tier retention '
'from _partition_inventory() with no new shared infrastructure.';

comment on column pgfr_record.wait_event_rollups_archive_v2.backend_type is
'Sourced from wait_event_map.state, which in this schema''s wait-sampling '
'encoding doubles as a backend_type proxy (inherited from the pre-retirement '
'design; not changed here).';

-- ---------------------------------------------------------------------------
-- 2. lock_rollups_archive_v2
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.lock_rollups_archive_v2 (
    sample_ts            int4        not null,
    start_time           timestamptz not null,
    end_time             timestamptz not null,
    lock_type            text,
    locked_relation_oid  oid,
    occurrence_count     integer     not null,
    max_duration         interval,
    avg_duration         interval
) partition by range (sample_ts);

create table if not exists pgfr_record.lock_rollups_archive_v2_default
    partition of pgfr_record.lock_rollups_archive_v2 default;

comment on table pgfr_record.lock_rollups_archive_v2 is
'Durable lock-contention summaries, one row per (lock_type, locked_relation_oid) '
'per ring rotation window. Daily RANGE-partitioned by sample_ts. No '
'blocked_user/blocking_user/sample_query columns: lock_samples (v2 ring) '
'stores pids, not usernames or query text, so the retired design''s columns '
'for those were always NULL and are not carried forward.';

-- ---------------------------------------------------------------------------
-- 3. activity_rollups_archive_v2
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.activity_rollups_archive_v2 (
    sample_ts         int4        not null,
    start_time        timestamptz not null,
    end_time          timestamptz not null,
    backend_type      text,
    state             text,
    duration_bucket   text        not null,  -- '<1s' | '1s-10s' | '10s-60s' | '1m-10m' | '10m+'
    occurrence_count  integer     not null,
    max_duration      interval,
    avg_duration      interval
) partition by range (sample_ts);

create table if not exists pgfr_record.activity_rollups_archive_v2_default
    partition of pgfr_record.activity_rollups_archive_v2 default;

comment on table pgfr_record.activity_rollups_archive_v2 is
'Durable session-activity summaries, one row per (backend_type, state, '
'duration_bucket) per ring rotation window. Daily RANGE-partitioned by '
'sample_ts. Grouped by concurrency/duration profile rather than the retired '
'activity_aggregates'' raw query_preview text: unbounded cardinality, and '
'redundant with statement_snapshots_v2''s real queryid-based stats. '
'duration_bucket is how long each sampled session had been running its '
'current query at sample time.';

-- ---------------------------------------------------------------------------
-- 4. Pre-create today's + tomorrow's partitions for all three tables.
-- ---------------------------------------------------------------------------
do $$
begin
    perform pgfr_record._ensure_partition('wait_event_rollups_archive_v2', current_date,
        'wait_event_type, wait_event, sample_ts desc');
    perform pgfr_record._ensure_partition('wait_event_rollups_archive_v2', current_date + 1,
        'wait_event_type, wait_event, sample_ts desc');

    perform pgfr_record._ensure_partition('lock_rollups_archive_v2', current_date,
        'lock_type, locked_relation_oid, sample_ts desc');
    perform pgfr_record._ensure_partition('lock_rollups_archive_v2', current_date + 1,
        'lock_type, locked_relation_oid, sample_ts desc');

    perform pgfr_record._ensure_partition('activity_rollups_archive_v2', current_date,
        'backend_type, state, sample_ts desc');
    perform pgfr_record._ensure_partition('activity_rollups_archive_v2', current_date + 1,
        'backend_type, state, sample_ts desc');
end $$;

-- ---------------------------------------------------------------------------
-- 5. _flush_ring_slot_to_rollups(p_slot) — called from rotate_ring() right
--    before it TRUNCATEs p_slot. Reads exactly that slot's current contents
--    (no watermark, no separate cadence): whatever's sitting in the slot at
--    this moment is exactly one rotation period's worth of non-overlapping
--    data, because rotate_ring() already advanced current_slot away from
--    p_slot before calling this. No-ops (returns silently) if the slot is
--    empty. Never raises: rotate_ring() also wraps this call in its own
--    EXCEPTION block, but this function guards its own three sections
--    independently so one section's failure doesn't blank out the other two.
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._flush_ring_slot_to_rollups(p_slot smallint)
returns void
language plpgsql as $$
declare
    v_window_start_ts int4;
    v_window_end_ts   int4;
    v_total_samples   bigint;
    v_start_time      timestamptz;
    v_end_time        timestamptz;
begin
    select min(sample_ts), max(sample_ts), count(distinct sample_ts)
    into v_window_start_ts, v_window_end_ts, v_total_samples
    from pgfr_record.wait_samples
    where slot = p_slot;

    if v_window_start_ts is null or v_total_samples = 0 then
        return;
    end if;

    v_start_time := pgfr_record.epoch() + v_window_start_ts * interval '1 second';
    v_end_time   := pgfr_record.epoch() + v_window_end_ts * interval '1 second';

    -- -----------------------------------------------------------------------
    -- Wait event rollup: decode wait_samples.data integer[] via wait_event_map.
    -- Encoding: [-wait_id, count, qmap_id, ...] repeated per wait group;
    -- negative entries mark a wait_event_map id (see sample_ring()).
    -- -----------------------------------------------------------------------
    begin
        perform pgfr_record._ensure_partition('wait_event_rollups_archive_v2', v_end_time::date,
            'wait_event_type, wait_event, sample_ts desc');

        insert into pgfr_record.wait_event_rollups_archive_v2 (
            sample_ts, start_time, end_time, backend_type, wait_event_type, wait_event,
            sample_count, total_waiters, avg_waiters, max_waiters, pct_of_samples
        )
        with decoded as (
            select
                ws.sample_ts,
                abs(ws.data[idx.i])::smallint as wait_id,
                ws.data[idx.i + 1]::int        as waiter_count
            from pgfr_record.wait_samples ws
            cross join lateral (
                select i
                from generate_subscripts(ws.data, 1) as i
                where ws.data[i] < 0
            ) idx
            where ws.slot = p_slot
        ),
        grouped as (
            select
                d.wait_id,
                count(distinct d.sample_ts) as sample_count,
                sum(d.waiter_count)         as total_waiters,
                round(avg(d.waiter_count), 2) as avg_waiters,
                max(d.waiter_count)         as max_waiters
            from decoded d
            group by d.wait_id
        )
        select
            v_window_end_ts, v_start_time, v_end_time,
            wem.state, wem.type, wem.event,
            g.sample_count, g.total_waiters, g.avg_waiters, g.max_waiters,
            round(100.0 * g.sample_count / nullif(v_total_samples, 0), 1)
        from grouped g
        join pgfr_record.wait_event_map wem on wem.id = g.wait_id;
    exception when others then
        -- Issue #101: this section's aggregate is lost when the slot is
        -- truncated after rotation; record the censoring event.
        perform pgfr_record._record_discontinuity(
            'rollup_flush_failed', 'wait_event_rollups_archive_v2',
            jsonb_build_object(
                'slot', p_slot, 'error', sqlerrm,
                'window_start', v_start_time, 'window_end', v_end_time,
                'total_samples', v_total_samples));
        raise warning 'pgfr_record: wait_event_rollups_archive_v2 flush failed for slot %: %',
            p_slot, sqlerrm;
    end;

    -- -----------------------------------------------------------------------
    -- Lock rollup: decode lock_samples.lock_type via lock_type_map.
    -- -----------------------------------------------------------------------
    begin
        perform pgfr_record._ensure_partition('lock_rollups_archive_v2', v_end_time::date,
            'lock_type, locked_relation_oid, sample_ts desc');

        insert into pgfr_record.lock_rollups_archive_v2 (
            sample_ts, start_time, end_time, lock_type, locked_relation_oid,
            occurrence_count, max_duration, avg_duration
        )
        select
            v_window_end_ts, v_start_time, v_end_time,
            ltm.lock_type, ls.locked_relation_oid,
            count(*),
            (max(ls.blocked_duration_s) * interval '1 second'),
            (avg(ls.blocked_duration_s) * interval '1 second')
        from pgfr_record.lock_samples ls
        left join pgfr_record.lock_type_map ltm on ltm.id = ls.lock_type
        where ls.slot = p_slot
        group by ltm.lock_type, ls.locked_relation_oid;
    exception when others then
        -- Issue #101: this section's aggregate is lost when the slot is
        -- truncated after rotation; record the censoring event.
        perform pgfr_record._record_discontinuity(
            'rollup_flush_failed', 'lock_rollups_archive_v2',
            jsonb_build_object(
                'slot', p_slot, 'error', sqlerrm,
                'window_start', v_start_time, 'window_end', v_end_time,
                'total_samples', v_total_samples));
        raise warning 'pgfr_record: lock_rollups_archive_v2 flush failed for slot %: %',
            p_slot, sqlerrm;
    end;

    -- -----------------------------------------------------------------------
    -- Activity rollup: bucket by backend_type/state/duration instead of raw
    -- query_preview text. duration is computed per-row from that row's own
    -- sample_ts (not the window's end_time uniformly, which the retired
    -- design used and which overstated duration for rows sampled early in
    -- the window).
    -- -----------------------------------------------------------------------
    begin
        perform pgfr_record._ensure_partition('activity_rollups_archive_v2', v_end_time::date,
            'backend_type, state, sample_ts desc');

        insert into pgfr_record.activity_rollups_archive_v2 (
            sample_ts, start_time, end_time, backend_type, state, duration_bucket,
            occurrence_count, max_duration, avg_duration
        )
        with durations as (
            select
                as2.backend_type,
                as2.state,
                (pgfr_record.epoch() + as2.sample_ts * interval '1 second') - as2.query_start as running_for
            from pgfr_record.activity_samples as2
            where as2.slot = p_slot
              and as2.query_start is not null
        )
        select
            v_window_end_ts, v_start_time, v_end_time,
            d.backend_type, d.state,
            case
                when d.running_for < interval '1 second'   then '<1s'
                when d.running_for < interval '10 seconds'  then '1s-10s'
                when d.running_for < interval '60 seconds'  then '10s-60s'
                when d.running_for < interval '10 minutes'  then '1m-10m'
                else '10m+'
            end as duration_bucket,
            count(*),
            max(d.running_for),
            avg(d.running_for)
        from durations d
        group by d.backend_type, d.state, duration_bucket;
    exception when others then
        -- Issue #101: this section's aggregate is lost when the slot is
        -- truncated after rotation; record the censoring event.
        perform pgfr_record._record_discontinuity(
            'rollup_flush_failed', 'activity_rollups_archive_v2',
            jsonb_build_object(
                'slot', p_slot, 'error', sqlerrm,
                'window_start', v_start_time, 'window_end', v_end_time,
                'total_samples', v_total_samples));
        raise warning 'pgfr_record: activity_rollups_archive_v2 flush failed for slot %: %',
            p_slot, sqlerrm;
    end;
end;
$$;

comment on function pgfr_record._flush_ring_slot_to_rollups(smallint) is
'Rolls up ring buffer slot p_slot into wait_event_rollups_archive_v2, '
'lock_rollups_archive_v2, and activity_rollups_archive_v2 before rotate_ring() '
'TRUNCATEs it. No-ops on an empty slot. Each of the three sections is '
'independently guarded so one failing does not blank the other two; '
'rotate_ring() additionally wraps the whole call so a rollup failure never '
'blocks ring rotation.';
