-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

create or replace function pgfr_analyze.v2_time_range(
    p_start timestamptz,
    p_end   timestamptz
)
returns table (ts_start int4, ts_end int4)
language sql immutable as $$
    select
        extract(epoch from (p_start - pgfr_record.epoch()))::int4,
        extract(epoch from (p_end   - pgfr_record.epoch()))::int4
$$;
comment on function pgfr_analyze.v2_time_range(timestamptz, timestamptz) is
'Convert timestamptz bounds to int4 sample_ts offsets (seconds since pgfr_record.epoch()). '
'Used by v2 reader functions to produce partition-prunable range predicates on sample_ts.';


-- Returns top queries by total_exec_time delta over the specified time window,
-- reading directly from the v2 partitioned table using int4 sample_ts ranges.
-- JIT is disabled at entry to avoid planning regressions on partitioned tables.
create or replace function pgfr_analyze.statement_activity_v2(
    p_start timestamptz,
    p_end   timestamptz,
    p_limit integer default 25
)
returns table(
    queryid                  bigint,
    dbid                     oid,
    userid                   oid,
    toplevel                 boolean,
    calls_delta              bigint,
    total_exec_time_delta_ms float8,
    mean_exec_time_ms        float8,
    rows_delta               bigint,
    shared_blks_hit_delta    bigint,
    shared_blks_read_delta   bigint,
    temp_blks_written_delta  bigint,
    hit_ratio_pct            numeric,
    pgss_reset_warning       boolean  -- true if any row flagged a cluster-wide PGSS eviction/reset
)
language plpgsql volatile as $$
declare
    v_ts_start int4;
    v_ts_end   int4;
begin
    set local jit = off;

    select tr.ts_start, tr.ts_end
    into v_ts_start, v_ts_end
    from pgfr_analyze.v2_time_range(p_start, p_end) tr;

    return query
    with
    -- last known state BEFORE the window opens — the baseline for delta computation.
    -- Using sample_ts < v_ts_start (not >= v_ts_start) is critical: picking the first
    -- row inside the window produces deltas relative to an arbitrary mid-window
    -- snapshot, understating activity for queries that ran before the window opened.
    snap_start as (
        select distinct on (ss.queryid, ss.dbid, ss.userid, ss.toplevel)
            ss.queryid, ss.dbid, ss.userid, ss.toplevel,
            ss.calls, ss.total_exec_time, ss.rows,
            ss.shared_blks_hit, ss.shared_blks_read, ss.temp_blks_written
        from pgfr_record.statement_snapshots_v2 ss
        where ss.sample_ts < v_ts_start
        order by ss.queryid, ss.dbid, ss.userid, ss.toplevel, ss.sample_ts desc
    ),
    -- latest snapshot per query inside the window — the end of the delta
    snap_end as (
        select distinct on (se.queryid, se.dbid, se.userid, se.toplevel)
            se.queryid, se.dbid, se.userid, se.toplevel,
            se.calls, se.total_exec_time, se.mean_exec_time, se.rows,
            se.shared_blks_hit, se.shared_blks_read, se.temp_blks_written,
            se.pgss_dealloc_warning
        from pgfr_record.statement_snapshots_v2 se
        where se.sample_ts >= v_ts_start
          and se.sample_ts <  v_ts_end
        order by se.queryid, se.dbid, se.userid, se.toplevel, se.sample_ts desc
    )
    select
        e.queryid,
        e.dbid,
        e.userid,
        e.toplevel,
        greatest(0, e.calls - coalesce(s.calls, 0))             as calls_delta,
        greatest(0, e.total_exec_time - coalesce(s.total_exec_time, 0)) as total_exec_time_delta_ms,
        e.mean_exec_time                                         as mean_exec_time_ms,
        greatest(0, e.rows - coalesce(s.rows, 0))               as rows_delta,
        greatest(0, e.shared_blks_hit  - coalesce(s.shared_blks_hit, 0))  as shared_blks_hit_delta,
        greatest(0, e.shared_blks_read - coalesce(s.shared_blks_read, 0)) as shared_blks_read_delta,
        greatest(0, e.temp_blks_written - coalesce(s.temp_blks_written, 0)) as temp_blks_written_delta,
        case
            when (greatest(0, e.shared_blks_hit - coalesce(s.shared_blks_hit, 0))
                + greatest(0, e.shared_blks_read - coalesce(s.shared_blks_read, 0))) > 0
            then round(
                100.0 * greatest(0, e.shared_blks_hit - coalesce(s.shared_blks_hit, 0))::numeric
                / (greatest(0, e.shared_blks_hit - coalesce(s.shared_blks_hit, 0))
                 + greatest(0, e.shared_blks_read - coalesce(s.shared_blks_read, 0))),
                1
            )
            else null
        end as hit_ratio_pct,
        coalesce(e.pgss_dealloc_warning, false) as pgss_reset_warning
    from snap_end e
    left join snap_start s using (queryid, dbid, userid, toplevel)
    where greatest(0, e.total_exec_time - coalesce(s.total_exec_time, 0)) > 0
    order by total_exec_time_delta_ms desc
    limit p_limit;
end;
$$;
comment on function pgfr_analyze.statement_activity_v2(timestamptz, timestamptz, integer) is
'Return top queries by total_exec_time delta over a time window, reading from '
'statement_snapshots_v2 (v2 partitioned table). Uses int4 sample_ts for partition '
'pruning — no join to snapshots table. JIT disabled at entry. Backwards-compatible: '
'existing statement_compare() is untouched. '
'pgss_reset_warning = true means a cluster-wide PGSS eviction occurred at that tick — '
'deltas for that row may be understated due to counter reset.';


-- Returns tables ordered by modification rate (n_tup_ins + n_tup_upd + n_tup_del delta)
-- over the specified time window, reading from the v2 partitioned table.
-- JIT is disabled at entry to avoid planning regressions on partitioned tables.
create or replace function pgfr_analyze.table_activity_v2(
    p_start timestamptz,
    p_end   timestamptz,
    p_limit integer default 25
)
returns table(
    relid                   oid,
    dbid                    oid,
    n_tup_ins_delta         bigint,
    n_tup_upd_delta         bigint,
    n_tup_del_delta         bigint,
    n_tup_hot_upd_delta     bigint,
    seq_scan_delta          bigint,
    idx_scan_delta          bigint,
    total_modifications     bigint,
    n_live_tup              bigint,
    n_dead_tup              bigint,
    dead_tup_pct            numeric,
    table_size_bytes        bigint
)
language plpgsql volatile as $$
declare
    v_ts_start int4;
    v_ts_end   int4;
begin
    set local jit = off;

    select tr.ts_start, tr.ts_end
    into v_ts_start, v_ts_end
    from pgfr_analyze.v2_time_range(p_start, p_end) tr;

    return query
    with
    -- last known state before the window — baseline for delta computation
    snap_start as (
        select distinct on (ts.relid, ts.dbid)
            ts.relid, ts.dbid,
            ts.n_tup_ins, ts.n_tup_upd, ts.n_tup_del, ts.n_tup_hot_upd,
            ts.seq_scan, ts.idx_scan
        from pgfr_record.table_snapshots_v2 ts
        where ts.sample_ts < v_ts_start
        order by ts.relid, ts.dbid, ts.sample_ts desc
    ),
    -- latest snapshot inside the window — end of the delta
    snap_end as (
        select distinct on (te.relid, te.dbid)
            te.relid, te.dbid,
            te.n_tup_ins, te.n_tup_upd, te.n_tup_del, te.n_tup_hot_upd,
            te.seq_scan, te.idx_scan,
            te.n_live_tup, te.n_dead_tup,
            te.table_size_bytes
        from pgfr_record.table_snapshots_v2 te
        where te.sample_ts >= v_ts_start
          and te.sample_ts <  v_ts_end
        order by te.relid, te.dbid, te.sample_ts desc
    )
    select
        e.relid,
        e.dbid,
        greatest(0, e.n_tup_ins - coalesce(s.n_tup_ins, 0))     as n_tup_ins_delta,
        greatest(0, e.n_tup_upd - coalesce(s.n_tup_upd, 0))     as n_tup_upd_delta,
        greatest(0, e.n_tup_del - coalesce(s.n_tup_del, 0))     as n_tup_del_delta,
        greatest(0, e.n_tup_hot_upd - coalesce(s.n_tup_hot_upd, 0)) as n_tup_hot_upd_delta,
        greatest(0, e.seq_scan - coalesce(s.seq_scan, 0))        as seq_scan_delta,
        greatest(0, e.idx_scan - coalesce(s.idx_scan, 0))        as idx_scan_delta,
        greatest(0, e.n_tup_ins - coalesce(s.n_tup_ins, 0))
            + greatest(0, e.n_tup_upd - coalesce(s.n_tup_upd, 0))
            + greatest(0, e.n_tup_del - coalesce(s.n_tup_del, 0)) as total_modifications,
        e.n_live_tup,
        e.n_dead_tup,
        case
            when coalesce(e.n_live_tup, 0) + coalesce(e.n_dead_tup, 0) > 0
            then round(
                100.0 * coalesce(e.n_dead_tup, 0)::numeric
                / (coalesce(e.n_live_tup, 0) + coalesce(e.n_dead_tup, 0)),
                1
            )
            else 0::numeric
        end as dead_tup_pct,
        e.table_size_bytes
    from snap_end e
    left join snap_start s using (relid, dbid)
    order by total_modifications desc
    limit p_limit;
end;
$$;
comment on function pgfr_analyze.table_activity_v2(timestamptz, timestamptz, integer) is
'Return tables ordered by modification rate (ins+upd+del delta) over a time window, '
'reading from table_snapshots_v2 (v2 partitioned table). Uses int4 sample_ts for '
'partition pruning. JIT disabled at entry. Backwards-compatible: existing '
'table_compare() and table_hotspots() are untouched.';


-- Returns indexes ordered by idx_scan delta over the specified time window,
-- reading from the v2 partitioned table using int4 sample_ts ranges.
-- JIT is disabled at entry to avoid planning regressions on partitioned tables.
create or replace function pgfr_analyze.index_activity_v2(
    p_start timestamptz,
    p_end   timestamptz,
    p_limit integer default 25
)
returns table(
    relid              oid,
    indexrelid         oid,
    dbid               oid,
    idx_scan_delta     bigint,
    idx_tup_read_delta bigint,
    idx_tup_fetch_delta bigint,
    index_size_bytes   bigint,
    selectivity_pct    numeric
)
language plpgsql volatile as $$
declare
    v_ts_start int4;
    v_ts_end   int4;
begin
    set local jit = off;

    select tr.ts_start, tr.ts_end
    into v_ts_start, v_ts_end
    from pgfr_analyze.v2_time_range(p_start, p_end) tr;

    return query
    with
    -- last known state before the window — baseline for delta computation
    snap_start as (
        select distinct on (si.relid, si.indexrelid, si.dbid)
            si.relid, si.indexrelid, si.dbid,
            si.idx_scan, si.idx_tup_read, si.idx_tup_fetch
        from pgfr_record.index_snapshots_v2 si
        where si.sample_ts < v_ts_start
        order by si.relid, si.indexrelid, si.dbid, si.sample_ts desc
    ),
    -- latest snapshot inside the window — end of the delta
    snap_end as (
        select distinct on (ie.relid, ie.indexrelid, ie.dbid)
            ie.relid, ie.indexrelid, ie.dbid,
            ie.idx_scan, ie.idx_tup_read, ie.idx_tup_fetch,
            ie.index_size_bytes
        from pgfr_record.index_snapshots_v2 ie
        where ie.sample_ts >= v_ts_start
          and ie.sample_ts <  v_ts_end
        order by ie.relid, ie.indexrelid, ie.dbid, ie.sample_ts desc
    )
    select
        e.relid,
        e.indexrelid,
        e.dbid,
        greatest(0, e.idx_scan      - coalesce(s.idx_scan, 0))      as idx_scan_delta,
        greatest(0, e.idx_tup_read  - coalesce(s.idx_tup_read, 0))  as idx_tup_read_delta,
        greatest(0, e.idx_tup_fetch - coalesce(s.idx_tup_fetch, 0)) as idx_tup_fetch_delta,
        e.index_size_bytes,
        case
            when greatest(0, e.idx_tup_read - coalesce(s.idx_tup_read, 0)) > 0
            then round(
                100.0 * greatest(0, e.idx_tup_fetch - coalesce(s.idx_tup_fetch, 0))::numeric
                / greatest(0, e.idx_tup_read - coalesce(s.idx_tup_read, 0)),
                1
            )
            else null
        end as selectivity_pct
    from snap_end e
    left join snap_start s using (relid, indexrelid, dbid)
    order by idx_scan_delta desc
    limit p_limit;
end;
$$;
comment on function pgfr_analyze.index_activity_v2(timestamptz, timestamptz, integer) is
'Return indexes ordered by idx_scan delta over a time window, reading from '
'index_snapshots_v2 (v2 partitioned table). Uses int4 sample_ts for partition '
'pruning. JIT disabled at entry. Backwards-compatible: existing index_efficiency() '
'and unused_indexes() are untouched.';

--------------------------------------------------------------------------------
-- ring buffer v2 reader functions
-- replace old ring-table reads with wait_samples, activity_samples, lock_samples.
-- output signatures unchanged — callers keep working.
--------------------------------------------------------------------------------

-- recent_waits_current() v2
-- decodes wait_samples integer[] via wait_event_map.
-- retention window: ring_config.num_slots * rotation_period.
drop function if exists pgfr_analyze.recent_waits_current();
create or replace function pgfr_analyze.recent_waits_current()
returns table (
    captured_at     timestamptz,
    backend_state   text,
    wait_event_type text,
    wait_event      text,
    state           text,
    count           integer
)
language sql stable as $$
    with retention_cutoff as (
        select
            pgfr_record.epoch()
            + (
                extract(epoch from now() - pgfr_record.epoch())::int4
                - (num_slots * extract(epoch from rotation_period)::int4)
              ) * interval '1 second' as cutoff
        from pgfr_record.ring_config
        where singleton
    ),
    decoded as (
        select
            pgfr_record.epoch() + ws.sample_ts * interval '1 second' as captured_at,
            abs(ws.data[i])::smallint                                 as wait_id,
            ws.data[i + 1]::integer                                   as waiter_count
        from pgfr_record.wait_samples ws,
             retention_cutoff rc,
             generate_subscripts(ws.data, 1) as i
        where ws.data[i] < 0
          and (pgfr_record.epoch() + ws.sample_ts * interval '1 second') > rc.cutoff
    )
    select
        d.captured_at,
        wem.state        as backend_state,
        wem.type         as wait_event_type,
        wem.event        as wait_event,
        wem.state        as state,
        d.waiter_count   as count
    from decoded d
    join pgfr_record.wait_event_map wem on wem.id = d.wait_id
    order by d.captured_at desc, d.waiter_count desc;
$$;

comment on function pgfr_analyze.recent_waits_current() is
'Ring buffer v2: decode wait_samples integer[] via wait_event_map. '
'Returns same columns as the original recent_waits_current(). '
'Retention window: num_slots * rotation_period from ring_config.';

-- recent_activity_current() v2
-- reads activity_samples (flat rows, no decode needed).
create or replace function pgfr_analyze.recent_activity_current()
returns table (
    captured_at      timestamptz,
    pid              integer,
    usename          text,
    application_name text,
    backend_type     text,
    state            text,
    wait_event_type  text,
    wait_event       text,
    query_start      timestamptz,
    running_for      interval,
    query_preview    text
)
language sql stable as $$
    with retention_cutoff as (
        select
            pgfr_record.epoch()
            + (
                extract(epoch from now() - pgfr_record.epoch())::int4
                - (num_slots * extract(epoch from rotation_period)::int4)
              ) * interval '1 second' as cutoff
        from pgfr_record.ring_config
        where singleton
    )
    select
        pgfr_record.epoch() + as2.sample_ts * interval '1 second' as captured_at,
        as2.pid,
        as2.usename,
        as2.application_name,
        as2.backend_type,
        as2.state,
        as2.wait_event_type,
        as2.wait_event,
        as2.query_start,
        (pgfr_record.epoch() + as2.sample_ts * interval '1 second') - as2.query_start as running_for,
        as2.query_preview
    from pgfr_record.activity_samples as2,
         retention_cutoff rc
    where (pgfr_record.epoch() + as2.sample_ts * interval '1 second') > rc.cutoff
      and as2.pid is not null
    order by as2.sample_ts desc, as2.query_start asc;
$$;

comment on function pgfr_analyze.recent_activity_current() is
'Ring buffer v2: reads activity_samples (flat per-backend rows). '
'Returns same columns as the original recent_activity_current(). '
'Retention window: num_slots * rotation_period from ring_config.';

-- recent_locks_current() v2
-- reads lock_samples; decodes lock_type via lock_type_map.
-- blocked_user, blocked_app, query_preview: not stored in lock_samples v2
-- (lock_samples stores pids only) — returned as null for now.
create or replace function pgfr_analyze.recent_locks_current()
returns table (
    captured_at            timestamptz,
    blocked_pid            integer,
    blocked_user           text,
    blocked_app            text,
    blocked_duration       interval,
    blocking_pid           integer,
    blocking_user          text,
    blocking_app           text,
    lock_type              text,
    locked_relation        text,
    blocked_query_preview  text,
    blocking_query_preview text
)
language sql stable as $$
    with retention_cutoff as (
        select
            pgfr_record.epoch()
            + (
                extract(epoch from now() - pgfr_record.epoch())::int4
                - (num_slots * extract(epoch from rotation_period)::int4)
              ) * interval '1 second' as cutoff
        from pgfr_record.ring_config
        where singleton
    )
    select
        pgfr_record.epoch() + ls.sample_ts * interval '1 second'   as captured_at,
        ls.blocked_pid,
        null::text                                                  as blocked_user,
        null::text                                                  as blocked_app,
        ls.blocked_duration_s * interval '1 second'                as blocked_duration,
        ls.blocking_pid,
        null::text                                                  as blocking_user,
        null::text                                                  as blocking_app,
        coalesce(ltm.lock_type, ls.lock_type::text)                as lock_type,
        coalesce(
            (ls.locked_relation_oid::regclass)::text,
            'oid:' || ls.locked_relation_oid::text
        )                                                           as locked_relation,
        null::text                                                  as blocked_query_preview,
        null::text                                                  as blocking_query_preview
    from pgfr_record.lock_samples ls
    cross join retention_cutoff rc
    left join pgfr_record.lock_type_map ltm on ltm.id = ls.lock_type
    where (pgfr_record.epoch() + ls.sample_ts * interval '1 second') > rc.cutoff
    order by ls.sample_ts desc, ls.blocked_duration_s desc nulls last;
$$;

comment on function pgfr_analyze.recent_locks_current() is
'Ring buffer v2: reads lock_samples; decodes lock_type via lock_type_map. '
'blocked_user, blocked_app, query_preview are null in v2 (pids only stored). '
'Returns same columns as the original recent_locks_current().';

-- wait_summary() v2
-- decodes wait_samples integer[] for a given time window.
drop function if exists pgfr_analyze.wait_summary(timestamptz, timestamptz);
create or replace function pgfr_analyze.wait_summary(
    p_start_time timestamptz,
    p_end_time   timestamptz
)
returns table (
    backend_state   text,
    wait_event_type text,
    wait_event      text,
    sample_count    bigint,
    total_waiters   bigint,
    avg_waiters     numeric,
    max_waiters     integer,
    pct_of_samples  numeric
)
language sql stable as $$
    with bounds as (
        select
            extract(epoch from p_start_time - pgfr_record.epoch())::int4 as start_ts,
            extract(epoch from p_end_time   - pgfr_record.epoch())::int4 as end_ts
    ),
    in_range as (
        select
            ws.sample_ts,
            abs(ws.data[i])::smallint  as wait_id,
            ws.data[i + 1]::integer    as waiter_count
        from pgfr_record.wait_samples ws,
             bounds b,
             generate_subscripts(ws.data, 1) as i
        where ws.data[i] < 0
          and ws.sample_ts between b.start_ts and b.end_ts
    ),
    total_samples as (
        select count(distinct sample_ts) as cnt from in_range
    ),
    grouped as (
        select
            wait_id,
            count(distinct sample_ts)   as sample_count,
            sum(waiter_count)           as total_waiters,
            round(avg(waiter_count), 2) as avg_waiters,
            max(waiter_count)           as max_waiters
        from in_range
        group by wait_id
    )
    select
        wem.state        as backend_state,
        wem.type         as wait_event_type,
        wem.event        as wait_event,
        g.sample_count,
        g.total_waiters,
        g.avg_waiters,
        g.max_waiters::integer,
        round(100.0 * g.sample_count / nullif(t.cnt, 0), 1) as pct_of_samples
    from grouped g
    cross join total_samples t
    join pgfr_record.wait_event_map wem on wem.id = g.wait_id
    order by g.total_waiters desc, g.sample_count desc;
$$;

comment on function pgfr_analyze.wait_summary(timestamptz, timestamptz) is
'Ring buffer v2: decode wait_samples integer[] for a time window. '
'Returns same columns as original wait_summary(). '
'Uses int4 sample_ts bounds for partition pruning.';

