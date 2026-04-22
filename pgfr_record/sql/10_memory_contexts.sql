-- MEMORY CONTEXT SAMPLING (self-sampling only)
-- Augments ring buffer v2 with per-backend memory context data from
-- pg_backend_memory_contexts (PG 14+).
--
-- Shape: one row per (pid, context) per tick. Follows the lock_samples pattern
-- (flat, many rows per tick, LIST-partitioned by slot, TRUNCATE on rotation).
--
-- Sampling is DEFAULT-OFF. Enabling captures the pgfr_record cron worker's
-- own memory contexts, which bounds pgfr's own footprint over time.
--
-- Scope limit: pg_backend_memory_contexts is caller-scoped — it only exposes
-- the calling backend's contexts. Cross-backend capture has no SQL-returning
-- API in any released Postgres: pg_log_backend_memory_contexts(pid) (PG 14+)
-- writes to the server log rather than returning rows, and
-- pg_get_process_memory_contexts was added during PG 18 development but
-- reverted before release. Adding cross-backend capture would require log
-- ingestion or a future PG API.
--------------------------------------------------------------------------------

-- 1. Config entries (all default-off)
insert into pgfr_record.config (key, value) values
    ('memory_context_sampling_enabled', 'false'),
    ('archive_memory_context_samples',  'true')
on conflict (key) do nothing;

-- 2. Dictionary — memory context names are repetitive across backends
create table if not exists pgfr_record.memory_context_name_map (
    id   smallint primary key generated always as identity (start with 1),
    name text not null unique
);

comment on table pgfr_record.memory_context_name_map is
'Memory context name dictionary: maps context name text -> smallint id. '
'Shared singleton, never truncated. Compresses repeated context names '
'(e.g., CacheMemoryContext, MessageContext) across many samples.';

-- 3. Race-safe name registration (same pattern as _register_wait)
create or replace function pgfr_record._register_memory_context_name(p_name text)
returns smallint
language plpgsql
as $$
declare
    v_id smallint;
begin
    select id into v_id from pgfr_record.memory_context_name_map where name = p_name;
    if v_id is not null then
        return v_id;
    end if;

    insert into pgfr_record.memory_context_name_map (name)
    values (p_name)
    on conflict (name) do nothing
    returning id into v_id;

    if v_id is not null then
        return v_id;
    end if;

    select id into v_id from pgfr_record.memory_context_name_map where name = p_name;
    return v_id;
end;
$$;

comment on function pgfr_record._register_memory_context_name(text) is
'Upsert a memory context name and return its smallint id. Race-safe.';

-- 4. Ring buffer tables: parent + partitions (LIST by slot)
do $$
declare
    v_n smallint;
    i   smallint;
begin
    select num_slots into v_n from pgfr_record.ring_config where singleton;

    execute $t$
        create table if not exists pgfr_record.memory_context_samples (
            sample_ts     int4     not null,
            pid           int4     not null,
            backend_type  text,
            name_id       smallint not null,
            parent_id     smallint,
            level         smallint,
            total_bytes   bigint,
            total_nblocks bigint,
            used_bytes    bigint,
            free_bytes    bigint,
            free_chunks  bigint,
            slot          smallint not null
        ) partition by list (slot)
    $t$;

    for i in 0..(v_n - 1) loop
        execute format(
            'create table if not exists pgfr_record.memory_context_samples_%s '
            'partition of pgfr_record.memory_context_samples for values in (%s)',
            i, i
        );
        execute format(
            'create index if not exists memory_context_samples_%s_ts_idx '
            'on pgfr_record.memory_context_samples_%s (sample_ts)',
            i, i
        );
        execute format(
            'create index if not exists memory_context_samples_%s_pid_idx '
            'on pgfr_record.memory_context_samples_%s (pid, sample_ts)',
            i, i
        );
    end loop;
end;
$$;

comment on table pgfr_record.memory_context_samples is
'Ring buffer: per-backend memory context samples. One row per (pid, context) per tick. '
'Partitioned by LIST(slot); TRUNCATE replaces old slot on rotation. '
'Populated by sample_memory_contexts() when memory_context_sampling_enabled=true.';

-- 5. Aggregate table (durable, written by flush_ring_to_aggregates)
create table if not exists pgfr_record.memory_context_aggregates (
    id                 bigserial primary key,
    start_time         timestamptz not null,
    end_time           timestamptz not null,
    backend_type       text,
    context_name       text,
    sample_count       int,
    distinct_pid_count int,
    sum_total_bytes    bigint,
    max_total_bytes    bigint,
    avg_total_bytes    bigint
);

create index if not exists memory_context_aggregates_end_time_idx
    on pgfr_record.memory_context_aggregates(end_time);
create index if not exists memory_context_aggregates_name_idx
    on pgfr_record.memory_context_aggregates(context_name, end_time);

comment on table pgfr_record.memory_context_aggregates is
'Aggregated memory context samples per flush window. One row per (context_name, backend_type).';

-- 6. Archive table (durable, written by archive_ring_samples)
create table if not exists pgfr_record.memory_context_samples_archive (
    id              bigserial primary key,
    sample_id       bigint not null,
    captured_at     timestamptz not null,
    pid             integer,
    backend_type    text,
    context_name    text,
    parent_name     text,
    level           integer,
    total_bytes     bigint,
    total_nblocks   bigint,
    used_bytes      bigint,
    free_bytes      bigint,
    free_chunks    bigint
);

create index if not exists memory_context_archive_captured_at_idx
    on pgfr_record.memory_context_samples_archive(captured_at);
create index if not exists memory_context_archive_sample_id_idx
    on pgfr_record.memory_context_samples_archive(sample_id);
create index if not exists memory_context_archive_pid_idx
    on pgfr_record.memory_context_samples_archive(pid, captured_at);
create index if not exists memory_context_archive_name_idx
    on pgfr_record.memory_context_samples_archive(context_name, captured_at);

comment on table pgfr_record.memory_context_samples_archive is
'Raw archives: memory context samples for forensic analysis. Names inlined (not dictionary-encoded).';

-- 7. Sampling function
--
-- PG 13: no-op (view does not exist).
-- PG 14+: inserts *this* backend's contexts (view is caller-scoped).
--
-- Returns number of rows inserted.
create or replace function pgfr_record.sample_memory_contexts()
returns int
language plpgsql
as $$
declare
    v_enabled       bool;
    v_slot          smallint;
    v_sample_ts     int4;
    v_pg_version    int;
    v_inserted      int := 0;
    v_backend_type  text;
begin
    v_enabled := coalesce(
        pgfr_record._get_config('memory_context_sampling_enabled', 'false')::bool,
        false
    );
    if not v_enabled then
        return 0;
    end if;

    v_pg_version := current_setting('server_version_num')::int;
    if v_pg_version < 140000 then
        return 0;
    end if;

    v_slot      := pgfr_record.ring_current_slot();
    v_sample_ts := extract(epoch from (clock_timestamp() - pgfr_record.epoch()))::int4;

    select backend_type into v_backend_type
      from pg_stat_activity where pid = pg_backend_pid();

    begin
        insert into pgfr_record.memory_context_name_map (name)
        select distinct n
          from (
              select name   as n from pg_backend_memory_contexts
              union
              select parent as n from pg_backend_memory_contexts
                where parent is not null
          ) u
        on conflict (name) do nothing;

        execute format(
            'insert into pgfr_record.memory_context_samples '
            '(sample_ts, pid, backend_type, name_id, parent_id, level, '
            ' total_bytes, total_nblocks, used_bytes, free_bytes, free_chunks, slot) '
            'select $1, pg_backend_pid(), $2, nm.id, pm.id, c.level, '
            '       c.total_bytes, c.total_nblocks, c.used_bytes, c.free_bytes, c.free_chunks, $3 '
            'from pg_backend_memory_contexts c '
            'join pgfr_record.memory_context_name_map nm on nm.name = c.name '
            'left join pgfr_record.memory_context_name_map pm on pm.name = c.parent'
        ) using v_sample_ts, v_backend_type, v_slot;

        get diagnostics v_inserted = row_count;
    exception when others then
        raise warning 'pgfr_record.sample_memory_contexts: self-sample failed [%]: %',
            sqlstate, sqlerrm;
    end;

    return v_inserted;
end;
$$;

comment on function pgfr_record.sample_memory_contexts() is
'Sample memory contexts into the ring. Default-off via memory_context_sampling_enabled. '
'PG 14+ captures the caller backend only (pg_backend_memory_contexts is caller-scoped). '
'Cross-backend sampling has no SQL-returning API in any released Postgres. Returns row count.';

-- 8. Redefine rotate_ring() to also TRUNCATE memory_context_samples_N
-- Superset of the 08_ring_buffer_v2.sql definition. Kept lock-step with it.
create or replace function pgfr_record.rotate_ring()
returns text
language plpgsql
as $$
declare
    v_old_slot        smallint;
    v_new_slot        smallint;
    v_truncate_slot   smallint;
    v_num_slots       smallint;
    v_rotation_period interval;
    v_rotated_at      timestamptz;
begin
    if not pg_try_advisory_xact_lock(hashtext('pgfr_rotate_ring')) then
        return 'skipped: another rotation in progress';
    end if;

    select current_slot, num_slots, rotation_period, rotated_at
    into v_old_slot, v_num_slots, v_rotation_period, v_rotated_at
    from pgfr_record.ring_config where singleton;

    if now() - v_rotated_at < v_rotation_period * 0.9 then
        return 'skipped: rotated too recently at ' || v_rotated_at::text;
    end if;

    begin
        set local lock_timeout = '2s';

        v_new_slot      := (v_old_slot + 1) % v_num_slots;
        v_truncate_slot := (v_new_slot + 1) % v_num_slots;

        update pgfr_record.ring_config
        set current_slot = v_new_slot, rotated_at = now()
        where singleton;

        execute format('truncate pgfr_record.wait_samples_%s', v_truncate_slot);
        execute format('truncate pgfr_record.lock_samples_%s', v_truncate_slot);
        execute format('truncate pgfr_record.query_map_%s', v_truncate_slot);
        execute format('truncate pgfr_record.activity_samples_%s', v_truncate_slot);
        execute format('truncate pgfr_record.memory_context_samples_%s', v_truncate_slot);
        execute format(
            'alter table pgfr_record.query_map_%s alter column id restart',
            v_truncate_slot
        );

        return format('rotated: slot %s -> %s, truncated slot %s',
                      v_old_slot, v_new_slot, v_truncate_slot);

    exception when lock_not_available then
        return 'failed: lock timeout on truncate, will retry next cycle';
    when others then
        raise;
    end;
end;
$$;

-- 9. Extend flush_ring_to_aggregates() with memory context aggregation.
-- Standalone function; the main flush calls it. Watermark is per-aggregate-table
-- so it can run independently of the wait/lock/activity flush path.
create or replace function pgfr_record._flush_memory_context_aggregates()
returns void
language plpgsql
as $$
declare
    v_last_end_ts   int4;
    v_start_ts      int4;
    v_end_ts        int4;
    v_start_time    timestamptz;
    v_end_time      timestamptz;
begin
    select coalesce(
        extract(epoch from max(end_time) - pgfr_record.epoch())::int4,
        0
    )
    into v_last_end_ts
    from pgfr_record.memory_context_aggregates;

    select min(sample_ts), max(sample_ts)
    into v_start_ts, v_end_ts
    from pgfr_record.memory_context_samples
    where sample_ts > v_last_end_ts;

    if v_start_ts is null then
        return;
    end if;

    v_start_time := pgfr_record.epoch() + v_start_ts * interval '1 second';
    v_end_time   := pgfr_record.epoch() + v_end_ts   * interval '1 second';

    insert into pgfr_record.memory_context_aggregates (
        start_time, end_time, backend_type, context_name,
        sample_count, distinct_pid_count,
        sum_total_bytes, max_total_bytes, avg_total_bytes
    )
    select
        v_start_time,
        v_end_time,
        s.backend_type,
        m.name                          as context_name,
        count(*)                        as sample_count,
        count(distinct s.pid)           as distinct_pid_count,
        sum(s.total_bytes)              as sum_total_bytes,
        max(s.total_bytes)              as max_total_bytes,
        avg(s.total_bytes)::bigint      as avg_total_bytes
    from pgfr_record.memory_context_samples s
    join pgfr_record.memory_context_name_map m on m.id = s.name_id
    where s.sample_ts > v_last_end_ts
    group by s.backend_type, m.name;
end;
$$;

comment on function pgfr_record._flush_memory_context_aggregates() is
'Flush memory_context_samples to memory_context_aggregates. Independent watermark.';

-- Rewire flush_ring_to_aggregates() to also call the memory context flush.
-- Superset of the 08_ring_buffer_v2.sql definition.
create or replace function pgfr_record.flush_ring_to_aggregates()
returns void
language plpgsql
as $$
declare
    v_start_ts      int4;
    v_end_ts        int4;
    v_start_time    timestamptz;
    v_end_time      timestamptz;
    v_total_samples bigint;
    v_last_flush_ts int4;
begin
    select coalesce(
        extract(epoch from max(end_time) - pgfr_record.epoch())::int4,
        0
    )
    into v_last_flush_ts
    from pgfr_record.wait_event_aggregates;

    select min(sample_ts), max(sample_ts), count(distinct sample_ts)
    into v_start_ts, v_end_ts, v_total_samples
    from pgfr_record.wait_samples
    where sample_ts > v_last_flush_ts;

    if v_start_ts is null or v_total_samples = 0 then
        -- Even when no wait samples exist, still flush memory contexts
        -- if they have new data — their watermark is independent.
        perform pgfr_record._flush_memory_context_aggregates();
        return;
    end if;

    v_start_time := pgfr_record.epoch() + v_start_ts * interval '1 second';
    v_end_time   := pgfr_record.epoch() + v_end_ts   * interval '1 second';

    insert into pgfr_record.wait_event_aggregates (
        start_time, end_time, backend_type, wait_event_type, wait_event, state,
        sample_count, total_waiters, avg_waiters, max_waiters, pct_of_samples
    )
    with decoded as (
        select
            ws.sample_ts,
            abs(ws.data[idx.i])::smallint             as wait_id,
            ws.data[idx.i + 1]::int                   as waiter_count
        from pgfr_record.wait_samples ws
        cross join lateral (
            select i
            from generate_subscripts(ws.data, 1) as i
            where ws.data[i] < 0
        ) idx
        where ws.sample_ts > v_last_flush_ts
    ),
    grouped as (
        select
            d.wait_id,
            count(distinct d.sample_ts)                    as sample_count,
            sum(d.waiter_count)                            as total_waiters,
            round(avg(d.waiter_count), 2)                  as avg_waiters,
            max(d.waiter_count)                            as max_waiters
        from decoded d
        group by d.wait_id
    )
    select
        v_start_time,
        v_end_time,
        wem.state        as backend_type,
        wem.type         as wait_event_type,
        wem.event        as wait_event,
        wem.state        as state,
        g.sample_count,
        g.total_waiters,
        g.avg_waiters,
        g.max_waiters,
        round(100.0 * g.sample_count / nullif(v_total_samples, 0), 1) as pct_of_samples
    from grouped g
    join pgfr_record.wait_event_map wem on wem.id = g.wait_id;

    insert into pgfr_record.lock_aggregates (
        start_time, end_time, blocked_user, blocking_user, lock_type,
        locked_relation_oid, occurrence_count, max_duration, avg_duration, sample_query
    )
    select
        v_start_time,
        v_end_time,
        null as blocked_user,
        null as blocking_user,
        ltm.lock_type,
        ls.locked_relation_oid,
        count(*)                    as occurrence_count,
        (max(ls.blocked_duration_s) * interval '1 second') as max_duration,
        (avg(ls.blocked_duration_s) * interval '1 second') as avg_duration,
        null as sample_query
    from pgfr_record.lock_samples ls
    left join pgfr_record.lock_type_map ltm on ltm.id = ls.lock_type
    where ls.sample_ts > v_last_flush_ts
    group by ltm.lock_type, ls.locked_relation_oid;

    insert into pgfr_record.activity_aggregates (
        start_time, end_time, query_preview, occurrence_count, max_duration, avg_duration
    )
    select
        v_start_time,
        v_end_time,
        as2.query_preview,
        count(*)                                               as occurrence_count,
        max(v_end_time - as2.query_start)                     as max_duration,
        avg(v_end_time - as2.query_start)                     as avg_duration
    from pgfr_record.activity_samples as2
    where as2.sample_ts > v_last_flush_ts
      and as2.query_start is not null
    group by as2.query_preview;

    perform pgfr_record._flush_memory_context_aggregates();

    raise notice 'pgfr_record: Flushed ring buffer (% to %, % samples)',
        v_start_time, v_end_time, v_total_samples;
end;
$$;

-- 10. Extend archive_ring_samples() to drain memory_context_samples.
create or replace function pgfr_record._archive_memory_context_samples(p_since_ts int4)
returns int
language plpgsql
as $$
declare
    v_rows int := 0;
    v_enabled bool;
begin
    v_enabled := coalesce(
        pgfr_record._get_config('archive_memory_context_samples', 'true')::bool,
        true
    );
    if not v_enabled then
        return 0;
    end if;

    insert into pgfr_record.memory_context_samples_archive (
        sample_id, captured_at, pid, backend_type, context_name, parent_name,
        level, total_bytes, total_nblocks, used_bytes, free_bytes, free_chunks
    )
    select
        s.sample_ts                                              as sample_id,
        pgfr_record.epoch() + s.sample_ts * interval '1 second'  as captured_at,
        s.pid,
        s.backend_type,
        m.name                                                   as context_name,
        pm.name                                                  as parent_name,
        s.level,
        s.total_bytes,
        s.total_nblocks,
        s.used_bytes,
        s.free_bytes,
        s.free_chunks
    from pgfr_record.memory_context_samples s
    join pgfr_record.memory_context_name_map m on m.id = s.name_id
    left join pgfr_record.memory_context_name_map pm on pm.id = s.parent_id
    where s.sample_ts > p_since_ts;

    get diagnostics v_rows = row_count;
    return v_rows;
end;
$$;

comment on function pgfr_record._archive_memory_context_samples(int4) is
'Drain memory_context_samples into its archive. Called from archive_ring_samples().';

create or replace function pgfr_record.archive_ring_samples()
returns void
language plpgsql
as $$
declare
    v_enabled             bool;
    v_archive_activity    bool;
    v_archive_locks       bool;
    v_archive_waits       bool;
    v_frequency_minutes   int;
    v_last_archive_ts     int4;
    v_next_archive_ts     int4;
    v_now_ts              int4;
    v_samples_to_archive  bigint;
    v_mc_samples_to_archive bigint;
    v_activity_rows       int := 0;
    v_lock_rows           int := 0;
    v_wait_rows           int := 0;
    v_mc_rows             int := 0;
begin
    v_enabled := coalesce(
        (select value::boolean from pgfr_record.config where key = 'archive_samples_enabled'),
        true
    );
    if not v_enabled then
        return;
    end if;

    v_archive_activity  := coalesce(
        (select value::boolean from pgfr_record.config where key = 'archive_activity_samples'), true);
    v_archive_locks     := coalesce(
        (select value::boolean from pgfr_record.config where key = 'archive_lock_samples'), true);
    v_archive_waits     := coalesce(
        (select value::boolean from pgfr_record.config where key = 'archive_wait_samples'), true);
    v_frequency_minutes := coalesce(
        (select value::int from pgfr_record.config where key = 'archive_sample_frequency_minutes'), 15);

    v_now_ts := extract(epoch from now() - pgfr_record.epoch())::int4;

    select coalesce(greatest(
        (select extract(epoch from max(captured_at) - pgfr_record.epoch())::int4
         from pgfr_record.activity_samples_archive),
        (select extract(epoch from max(captured_at) - pgfr_record.epoch())::int4
         from pgfr_record.lock_samples_archive),
        (select extract(epoch from max(captured_at) - pgfr_record.epoch())::int4
         from pgfr_record.wait_samples_archive),
        (select extract(epoch from max(captured_at) - pgfr_record.epoch())::int4
         from pgfr_record.memory_context_samples_archive)
    ), 0)
    into v_last_archive_ts;

    v_next_archive_ts := v_last_archive_ts + v_frequency_minutes * 60;

    if v_now_ts < v_next_archive_ts then
        return;
    end if;

    select count(distinct sample_ts)
    into v_samples_to_archive
    from pgfr_record.wait_samples
    where sample_ts > v_last_archive_ts;

    select count(distinct sample_ts)
    into v_mc_samples_to_archive
    from pgfr_record.memory_context_samples
    where sample_ts > v_last_archive_ts;

    if v_samples_to_archive = 0 and v_mc_samples_to_archive = 0 then
        return;
    end if;

    if v_archive_activity then
        insert into pgfr_record.activity_samples_archive (
            sample_id, captured_at, pid, usename, application_name, client_addr,
            backend_type, state, wait_event_type, wait_event,
            backend_start, xact_start, query_start, state_change, query_preview
        )
        select
            as2.sample_ts                                                 as sample_id,
            pgfr_record.epoch() + as2.sample_ts * interval '1 second'    as captured_at,
            as2.pid,
            as2.usename,
            as2.application_name,
            as2.client_addr,
            as2.backend_type,
            as2.state,
            as2.wait_event_type,
            as2.wait_event,
            as2.backend_start,
            as2.xact_start,
            as2.query_start,
            as2.state_change,
            as2.query_preview
        from pgfr_record.activity_samples as2
        where as2.sample_ts > v_last_archive_ts;
        get diagnostics v_activity_rows = row_count;
    end if;

    if v_archive_locks then
        insert into pgfr_record.lock_samples_archive (
            sample_id, captured_at, blocked_pid, blocked_user, blocked_app,
            blocked_query_preview, blocked_duration, blocking_pid, blocking_user,
            blocking_app, blocking_query_preview, lock_type, locked_relation_oid
        )
        select
            ls.sample_ts                                                  as sample_id,
            pgfr_record.epoch() + ls.sample_ts * interval '1 second'     as captured_at,
            ls.blocked_pid,
            null                                                          as blocked_user,
            null                                                          as blocked_app,
            null                                                          as blocked_query_preview,
            ls.blocked_duration_s * interval '1 second'                  as blocked_duration,
            ls.blocking_pid,
            null                                                          as blocking_user,
            null                                                          as blocking_app,
            null                                                          as blocking_query_preview,
            ltm.lock_type,
            ls.locked_relation_oid
        from pgfr_record.lock_samples ls
        left join pgfr_record.lock_type_map ltm on ltm.id = ls.lock_type
        where ls.sample_ts > v_last_archive_ts;
        get diagnostics v_lock_rows = row_count;
    end if;

    if v_archive_waits then
        insert into pgfr_record.wait_samples_archive (
            sample_id, captured_at, backend_type, wait_event_type, wait_event, state, count
        )
        with decoded as (
            select
                ws.sample_ts,
                abs(ws.data[idx.i])::smallint    as wait_id,
                ws.data[idx.i + 1]::int          as waiter_count
            from pgfr_record.wait_samples ws
            cross join lateral (
                select i
                from generate_subscripts(ws.data, 1) as i
                where ws.data[i] < 0
            ) idx
            where ws.sample_ts > v_last_archive_ts
        )
        select
            d.sample_ts                                                   as sample_id,
            pgfr_record.epoch() + d.sample_ts * interval '1 second'      as captured_at,
            wem.state                                                     as backend_type,
            wem.type                                                      as wait_event_type,
            wem.event                                                     as wait_event,
            wem.state                                                     as state,
            d.waiter_count                                                as count
        from decoded d
        join pgfr_record.wait_event_map wem on wem.id = d.wait_id;
        get diagnostics v_wait_rows = row_count;
    end if;

    v_mc_rows := pgfr_record._archive_memory_context_samples(v_last_archive_ts);

    raise notice 'pgfr_record: Archived raw samples (% samples, % activity, % lock, % wait, % mc)',
        v_samples_to_archive, v_activity_rows, v_lock_rows, v_wait_rows, v_mc_rows;
end;
$$;

-- 11. pg_cron wiring: sampler runs at 1-minute cadence (matches sample_ring)
do $$
begin
    if exists (select from pg_extension where extname = 'pg_cron') then
        perform cron.schedule('pgfr-sample-memory', '* * * * *',
            'set statement_timeout = ''500ms''; select pgfr_record.sample_memory_contexts()')
        where not exists (select 1 from cron.job where jobname = 'pgfr-sample-memory');

        update cron.job set nodename = ''
        where jobname = 'pgfr-sample-memory'
          and nodename <> '';
    end if;
exception when others then
    null;
end $$;
