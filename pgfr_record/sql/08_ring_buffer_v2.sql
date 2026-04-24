-- RING BUFFER v2: N-partition TRUNCATE-based rotation
-- Follows pg_ash design (ash-install.sql). Replaces the UPDATE-based ring buffer
-- (samples_ring / wait_samples_ring / lock_samples_ring) with a LOGGED, partitioned,
-- INSERT-only design. Dual operation during migration — legacy tables preserved.
--
-- Key differences from pg_ash:
--   - N configurable partitions (default 3, min 3) vs hardcoded 3
--   - Separate wait_samples and lock_samples tables (not a single ash.sample)
--   - pgfr_record namespace, snake_case identifiers throughout
--------------------------------------------------------------------------------

-- 1. New config entries (ring_buffer_partitions, ring_rotation_period)
insert into pgfr_record.config (key, value) values
    ('ring_buffer_partitions', '3'),
    ('ring_rotation_period',   '2 hours')
on conflict (key) do nothing;

comment on table pgfr_record.config is
'Key-value configuration store for pgfr_record. '
'ring_buffer_partitions: number of ring buffer partitions (min 3, default 3). '
'ring_rotation_period: how often to rotate ring partitions (default 2 hours).';

-- 2. Ring config singleton — num_slots and rotation_period set from config at install time
create table if not exists pgfr_record.ring_config (
    singleton       bool primary key default true check (singleton),
    current_slot    smallint  not null default 0,
    num_slots       smallint  not null default 3 check (num_slots >= 3),
    rotation_period interval  not null default '2 hours',
    rotated_at      timestamptz not null default clock_timestamp()
);

comment on table pgfr_record.ring_config is
'Ring buffer rotation state singleton. '
'current_slot: partition currently being written (0..num_slots-1). '
'num_slots: number of partitions, set at install time from ring_buffer_partitions config. '
'rotation_period: how often to advance the slot. '
'rotated_at: timestamp of last rotation.';

insert into pgfr_record.ring_config (singleton, num_slots, rotation_period)
select
    true,
    greatest(3, coalesce(pgfr_record._get_config('ring_buffer_partitions', '3')::smallint, 3)),
    coalesce(pgfr_record._get_config('ring_rotation_period', '2 hours')::interval, '2 hours')
on conflict do nothing;

-- 3. Wait event dictionary — shared singleton, never truncated
-- Maps (state, type, event) → compact smallint id.
-- Bounded by the number of distinct PG wait events (~600 max).
create table if not exists pgfr_record.wait_event_map (
    id    smallint primary key generated always as identity (start with 1),
    state text not null,
    type  text not null,
    event text not null,
    unique (state, type, event)
);

comment on table pgfr_record.wait_event_map is
'Wait event dictionary: maps (state, type, event) → smallint id. '
'Shared singleton — never truncated. Max ~600 entries (bounded by PG wait events). '
'Used to compress wait event data in the encoded integer[] arrays of wait_samples.';

-- 4. Dynamic partition creation for wait_samples, lock_samples, query_map_N
do $$
declare
    v_n smallint;
    i   smallint;
begin
    select num_slots into v_n from pgfr_record.ring_config where singleton;

    -- wait_samples parent: LOGGED, partitioned by LIST(slot)
    -- Stores encoded integer[] per-database wait event snapshots.
    -- Encoding: [-wait_id, count, qid, qid, ..., -next_wait_id, count, ...]
    execute $t$
        create table if not exists pgfr_record.wait_samples (
            sample_ts    int4     not null,
            datid        oid      not null,
            active_count smallint not null,
            data         integer[] not null
                         check (data[1] < 0 and array_length(data, 1) >= 3),
            slot         smallint not null
        ) partition by list (slot)
    $t$;

    -- lock_samples parent: LOGGED, partitioned by LIST(slot)
    execute $t$
        create table if not exists pgfr_record.lock_samples (
            sample_ts           int4     not null,
            blocked_pid         int4     not null,
            blocked_qid         int4,
            blocked_duration_s  int4,
            blocking_pid        int4     not null,
            blocking_qid        int4,
            lock_type           smallint not null,
            locked_relation_oid oid,
            slot                smallint not null
        ) partition by list (slot)
    $t$;

    -- create N partitions + query_maps
    for i in 0..(v_n - 1) loop
        -- wait_samples_N
        execute format(
            'create table if not exists pgfr_record.wait_samples_%s '
            'partition of pgfr_record.wait_samples for values in (%s)',
            i, i
        );
        execute format(
            'create index if not exists wait_samples_%s_ts_idx '
            'on pgfr_record.wait_samples_%s (sample_ts)',
            i, i
        );

        -- lock_samples_N
        execute format(
            'create table if not exists pgfr_record.lock_samples_%s '
            'partition of pgfr_record.lock_samples for values in (%s)',
            i, i
        );
        execute format(
            'create index if not exists lock_samples_%s_ts_idx '
            'on pgfr_record.lock_samples_%s (sample_ts)',
            i, i
        );

        -- query_map_N: per-partition query_id dictionary, TRUNCATE with partition on rotation
        execute format(
            'create table if not exists pgfr_record.query_map_%s ('
            '    id       int4 primary key generated always as identity (start with 1),'
            '    query_id int8 not null unique'
            ')',
            i
        );
    end loop;
end;
$$;

comment on table pgfr_record.wait_samples is
'Ring buffer v2: encoded wait event samples. One row per (database, wait group) per tick. '
'data integer[] encoding: [-wait_id, count, query_map_id, ...] groups, repeated per wait event. '
'Partitioned by LIST(slot); TRUNCATE replaces old slot on rotation. Never DELETEd.';

comment on table pgfr_record.lock_samples is
'Ring buffer v2: lock contention samples. One row per blocked/blocking pair per tick. '
'Partitioned by LIST(slot); TRUNCATE replaces old slot on rotation.';

-- 5. query_map_all view — union of all N per-partition query dictionaries
-- Must be created after the DO block (N is dynamic).
-- Recreate on each install to pick up num_slots changes.
do $$
declare
    v_n     smallint;
    v_parts text[] := array[]::text[];
    i       smallint;
    v_sql   text;
begin
    select num_slots into v_n from pgfr_record.ring_config where singleton;
    for i in 0..(v_n - 1) loop
        v_parts := v_parts || format(
            'select %s::smallint as slot, id, query_id from pgfr_record.query_map_%s',
            i, i
        );
    end loop;
    v_sql := 'create or replace view pgfr_record.query_map_all as '
             || array_to_string(v_parts, ' union all ');
    execute v_sql;
end;
$$;

comment on view pgfr_record.query_map_all is
'Union of all per-partition query_map tables. '
'Planner eliminates non-matching partitions when slot is a constant in reader queries. '
'Recreated on each install to reflect num_slots.';

-- 6. Helper functions

-- Current slot (stable — reads ring_config singleton)
create or replace function pgfr_record.ring_current_slot()
returns smallint
language sql stable parallel safe
as $$
    select current_slot from pgfr_record.ring_config where singleton
$$;

comment on function pgfr_record.ring_current_slot() is
'Returns the current ring buffer slot (0..num_slots-1). '
'Stable within a transaction. Use this in INSERT statements to target the correct partition.';

-- Register wait event (upsert, returns id) — race-safe, same pattern as ash._register_wait()
create or replace function pgfr_record._register_wait(p_state text, p_type text, p_event text)
returns smallint
language plpgsql
as $$
declare
    v_id smallint;
begin
    -- fast path: already registered
    select id into v_id
    from pgfr_record.wait_event_map
    where state = p_state and type = p_type and event = p_event;
    if v_id is not null then
        return v_id;
    end if;

    -- insert, ignore race
    insert into pgfr_record.wait_event_map (state, type, event)
    values (p_state, p_type, p_event)
    on conflict (state, type, event) do nothing
    returning id into v_id;

    if v_id is not null then
        return v_id;
    end if;

    -- race condition: another session inserted first
    select id into v_id
    from pgfr_record.wait_event_map
    where state = p_state and type = p_type and event = p_event;
    return v_id;
end;
$$;

comment on function pgfr_record._register_wait(text, text, text) is
'Upsert (state, type, event) into wait_event_map and return its smallint id. '
'Race-safe: three-step insert with concurrent-insert fallback. '
'Called once per distinct wait event per sample tick.';

-- Register query_id in current slot''s query_map (dynamic dispatch)
create or replace function pgfr_record._register_query(p_query_id int8)
returns int4
language plpgsql
as $$
declare
    v_slot smallint;
    v_id   int4;
begin
    v_slot := pgfr_record.ring_current_slot();
    -- single round-trip: INSERT ... ON CONFLICT DO UPDATE (no-op) RETURNING id
    -- avoids a separate SELECT when the row already exists
    execute format(
        'insert into pgfr_record.query_map_%s (query_id) values ($1) '
        'on conflict (query_id) do update set query_id = excluded.query_id '
        'returning id',
        v_slot
    ) into v_id using p_query_id;
    return v_id;
end;
$$;

comment on function pgfr_record._register_query(int8) is
'Register a query_id in the current slot''s query_map table. '
'Returns the local int4 id (sequence-based, resets on TRUNCATE at rotation). '
'Single round-trip via INSERT ... ON CONFLICT DO UPDATE RETURNING id. '
'Called during sample_ring() to build the query_map ids used in data encoding.';

-- 7. rotate_ring() — N-partition TRUNCATE rotation
-- Advisory lock prevents concurrent rotation from pg_cron overlap.
-- Advances current_slot first, then TRUNCATEs the oldest partition.
--
-- Uses pg_try_advisory_xact_lock (not session-level pg_try_advisory_lock) so
-- the lock is automatically released on transaction end — including on errors.
-- Session-level locks inside exception handlers are not released when the
-- handler's subtransaction rolls back, causing lock leaks on unexpected errors.
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
    -- xact-level: auto-released on commit or rollback — no explicit unlock needed
    if not pg_try_advisory_xact_lock(hashtext('pgfr_rotate_ring')) then
        return 'skipped: another rotation in progress';
    end if;

    select current_slot, num_slots, rotation_period, rotated_at
    into v_old_slot, v_num_slots, v_rotation_period, v_rotated_at
    from pgfr_record.ring_config where singleton;

    -- idempotent: skip if rotated too recently (within 90% of rotation_period)
    if now() - v_rotated_at < v_rotation_period * 0.9 then
        return 'skipped: rotated too recently at ' || v_rotated_at::text;
    end if;

    begin
        set local lock_timeout = '2s';

        v_new_slot      := (v_old_slot + 1) % v_num_slots;
        -- truncate the slot that's now two steps ahead (oldest data)
        v_truncate_slot := (v_new_slot + 1) % v_num_slots;

        -- advance slot FIRST: new inserts go to v_new_slot before we truncate
        update pgfr_record.ring_config
        set current_slot = v_new_slot, rotated_at = now()
        where singleton;

        -- lockstep TRUNCATE — zero bloat, no dead tuples, no GC needed
        execute format('truncate pgfr_record.wait_samples_%s', v_truncate_slot);
        execute format('truncate pgfr_record.lock_samples_%s', v_truncate_slot);
        execute format('truncate pgfr_record.query_map_%s', v_truncate_slot);
        execute format('truncate pgfr_record.activity_samples_%s', v_truncate_slot);
        -- restart identity sequence so ids are compact after rotation
        execute format(
            'alter table pgfr_record.query_map_%s alter column id restart',
            v_truncate_slot
        );

        return format('rotated: slot %s -> %s, truncated slot %s',
                      v_old_slot, v_new_slot, v_truncate_slot);

    exception when lock_not_available then
        -- xact-level advisory lock released automatically on rollback
        return 'failed: lock timeout on truncate, will retry next cycle';
    when others then
        raise;
    end;
end;
$$;

comment on function pgfr_record.rotate_ring() is
'Rotate ring buffer partitions: advance current_slot, TRUNCATE the oldest partition '
'and its matching query_map. Dynamic N-partition support (reads num_slots from ring_config). '
'Idempotent within 90% of rotation_period. Advisory lock prevents concurrent rotation. '
'Returns text status: rotated / skipped / failed.';

-- 8. sample_ring() — INSERT-based sampler (replaces UPDATE pattern)
-- Implements the same integer[] encoding as ash.take_sample():
--   [-wait_id, count, qmap_id, qmap_id, ...]  — one group per (datid, wait_event)
-- Keeps existing pgfr_record.sample() intact for dual operation during migration.
create or replace function pgfr_record.sample_ring()
returns timestamptz
language plpgsql
as $$
declare
    v_slot              smallint;
    v_sample_ts         int4;
    v_captured_at       timestamptz;
    v_include_bg        bool;
    v_debug_logging     bool;
    v_current_slot      smallint;
    v_rec               record;
    v_datid_rec         record;
    v_data              integer[];
    v_active_count      smallint;
    v_seen_waits        text[] := '{}';
    v_rows_inserted     int    := 0;
begin
    v_captured_at := clock_timestamp();
    v_sample_ts   := extract(epoch from (v_captured_at - pgfr_record.epoch()))::int4;
    v_slot        := pgfr_record.ring_current_slot();

    -- config (reuse existing config helpers)
    v_include_bg    := coalesce(pgfr_record._get_config('include_bg_workers', 'false')::bool, false);
    v_debug_logging := coalesce(pgfr_record._get_config('debug_logging', 'false')::bool, false);

    -- -----------------------------------------------------------------------
    -- Read 1: register new wait events; walk pg_stat_activity once.
    -- CPU* = active backend with no wait event (genuine CPU or uninstrumented).
    -- IdleTx = idle in transaction (may hold locks).
    -- -----------------------------------------------------------------------
    for v_rec in
        select
            sa.pid,
            sa.state,
            coalesce(sa.wait_event_type,
                case
                    when sa.state = 'active'                   then 'CPU*'
                    when sa.state like 'idle in transaction%'  then 'IdleTx'
                end
            ) as wait_type,
            coalesce(sa.wait_event,
                case
                    when sa.state = 'active'                   then 'CPU*'
                    when sa.state like 'idle in transaction%'  then 'IdleTx'
                end
            ) as wait_event,
            sa.backend_type,
            null::bigint as query_id   -- populated per-session via query_map on PG14+
        from pg_stat_activity sa
        where sa.state in ('active', 'idle in transaction', 'idle in transaction (aborted)')
          and (sa.backend_type = 'client backend'
           or (v_include_bg and sa.backend_type in (
                   'autovacuum worker', 'logical replication worker',
                   'parallel worker', 'background worker')))
          and sa.pid <> pg_backend_pid()
    loop
        -- dedup in memory; avoid per-row catalog lookup
        if not (v_rec.state || '|' || v_rec.wait_type || '|' || v_rec.wait_event = any(v_seen_waits)) then
            v_seen_waits := v_seen_waits
                || (v_rec.state || '|' || v_rec.wait_type || '|' || v_rec.wait_event);
            if not exists (
                select from pgfr_record.wait_event_map
                where state = v_rec.state and type = v_rec.wait_type and event = v_rec.wait_event
            ) then
                perform pgfr_record._register_wait(v_rec.state, v_rec.wait_type, v_rec.wait_event);
            end if;
        end if;

        if v_debug_logging then
            raise log 'pgfr_record.sample_ring: pid=% state=% wait_type=% wait_event=% backend_type=% query_id=%',
                v_rec.pid, v_rec.state, v_rec.wait_type, v_rec.wait_event,
                v_rec.backend_type, coalesce(v_rec.query_id::text, '(null)');
        end if;
    end loop;

    -- -----------------------------------------------------------------------
    -- Read 2: register query_ids into current slot's query_map
    -- query_id in pg_stat_activity requires PG14+; skip on PG13.
    -- -----------------------------------------------------------------------
    if (select current_setting('server_version_num')::int) >= 140000 then
    execute format(
        'insert into pgfr_record.query_map_%s (query_id) '
        'select distinct sa.query_id '
        'from pg_stat_activity sa '
        'where sa.query_id is not null '
        '  and sa.state in (''active'', ''idle in transaction'', ''idle in transaction (aborted)'') '
        '  and (sa.backend_type = ''client backend'' '
        '   or ($1 and sa.backend_type in ('
        '       ''autovacuum worker'', ''logical replication worker'', '
        '       ''parallel worker'', ''background worker''))) '
        '  and sa.pid <> pg_backend_pid() '
        '  and (select reltuples from pg_class '
        '       where oid = ''pgfr_record.query_map_%s''::regclass) < 50000 '
        'on conflict (query_id) do nothing',
        v_slot, v_slot
    ) using v_include_bg;
    end if; -- PG14+ query_id guard

    -- -----------------------------------------------------------------------
    -- Reads 3+4: per-database encoding — same CTE pattern as ash.take_sample()
    -- Snapshot pg_stat_activity, group by (datid, wait_event), encode integer[].
    -- Format: [-wait_id, count, qmap_id, qmap_id, ..., -next_wait_id, ...]
    -- -----------------------------------------------------------------------
    for v_datid_rec in
        select distinct coalesce(sa.datid, 0::oid) as datid
        from pg_stat_activity sa
        where sa.state in ('active', 'idle in transaction', 'idle in transaction (aborted)')
          and (sa.backend_type = 'client backend'
           or (v_include_bg and sa.backend_type in (
                   'autovacuum worker', 'logical replication worker',
                   'parallel worker', 'background worker')))
          and sa.pid <> pg_backend_pid()
    loop
        begin
            -- single query: snapshot → group by wait → encode → flatten
            -- mirrors ash.take_sample() CTE exactly, adapted to pgfr_record
            execute format(
                'with snapshot as ( '
                '    select '
                '        wm.id as wait_id, '
                '        coalesce(m.id, 0) as map_id '
                '    from pg_stat_activity sa '
                '    join pgfr_record.wait_event_map wm '
                '         on wm.state = sa.state '
                '        and wm.type = coalesce(sa.wait_event_type, '
                '            case when sa.state = ''active'' then ''CPU*'' '
                '                 when sa.state like ''idle in transaction%%'' then ''IdleTx'' end) '
                '        and wm.event = coalesce(sa.wait_event, '
                '            case when sa.state = ''active'' then ''CPU*'' '
                '                 when sa.state like ''idle in transaction%%'' then ''IdleTx'' end) '
                '    left join pgfr_record.query_map_all m '
                '           on m.slot = %s::smallint and m.query_id = sa.query_id '
                '    where sa.state in (''active'', ''idle in transaction'', ''idle in transaction (aborted)'') '
                '      and (sa.backend_type = ''client backend'' '
                '       or ($1 and sa.backend_type in ( '
                '           ''autovacuum worker'', ''logical replication worker'', '
                '           ''parallel worker'', ''background worker''))) '
                '      and sa.pid <> pg_backend_pid() '
                '      and coalesce(sa.datid, 0::oid) = $2 '
                '), '
                'groups as ( '
                '    select '
                '        row_number() over (order by s.wait_id) as gnum, '
                '        array[(-s.wait_id)::integer, count(*)::integer] '
                '            || array_agg(s.map_id::integer) as group_arr '
                '    from snapshot s '
                '    group by s.wait_id '
                '), '
                'flat as ( '
                '    select array_agg(el order by g.gnum, u.ord) as data '
                '    from groups g, '
                '         lateral unnest(g.group_arr) with ordinality as u(el, ord) '
                '), '
                'backend_count as ( '
                '    select count(*)::smallint as cnt from snapshot '
                ') '
                'select f.data, bc.cnt from flat f, backend_count bc',
                v_slot
            ) into v_data, v_active_count using v_include_bg, v_datid_rec.datid;

            if v_data is not null and array_length(v_data, 1) >= 3 then
                insert into pgfr_record.wait_samples (sample_ts, datid, active_count, data, slot)
                values (v_sample_ts, v_datid_rec.datid, v_active_count, v_data, v_slot);
                v_rows_inserted := v_rows_inserted + 1;
            end if;

        exception when others then
            raise warning 'pgfr_record.sample_ring: error encoding sample for datid % [%]: %',
                v_datid_rec.datid, sqlstate, sqlerrm;
        end;
    end loop;

    return v_captured_at;
end;
$$;

comment on function pgfr_record.sample_ring() is
'Ring buffer v2 sampler: INSERT-based replacement for the UPDATE pattern in sample(). '
'Encodes wait events as integer[] arrays: [-wait_id, count, qmap_id, ...] per database. '
'Follows the ash.take_sample() encoding exactly. '
'Dual operation: existing sample() continues to work during migration. '
'Call via pg_cron; use rotate_ring() separately on a slower schedule.';

-- 9. pg_cron wiring — consolidated into pgfr_record.enable() (see 05_functions_ops.sql).
-- install.sql calls enable() as its final step; the scheduling lived here previously.

-- 10. Reader view: recent_waits_v2
-- Decodes the integer[] format to human-readable wait events.
-- Finds all negative elements (wait_event_id markers) in each data array
-- and joins to wait_event_map. For full per-backend decode see ash.decode_sample().
create or replace view pgfr_record.recent_waits_v2 as
select
    pgfr_record.epoch() + s.sample_ts * interval '1 second' as captured_at,
    s.datid,
    s.active_count,
    wem.state,
    wem.type  as wait_event_type,
    wem.event as wait_event,
    s.slot
from pgfr_record.wait_samples s
cross join lateral (
    select abs(s.data[i])::smallint as wid
    from generate_subscripts(s.data, 1) as i
    where s.data[i] < 0
) ids
join pgfr_record.wait_event_map wem on wem.id = ids.wid;

comment on view pgfr_record.recent_waits_v2 is
'Ring buffer v2 reader: decodes wait_samples integer[] encoding to readable rows. '
'One row per (sample, database, wait_event). '
'For count and query_id resolution, use ash.decode_sample()-style decoding.';

--------------------------------------------------------------------------------
-- 11. activity_samples: flat per-backend rows, LIST-partitioned by slot
-- Complements wait_samples (encoded integer[]) with raw session detail
-- needed by archive_ring_samples() and flush_ring_to_aggregates().
-- One row per active backend per tick (top 25 by query age, same as old ring).
--------------------------------------------------------------------------------

do $$
declare
    v_n smallint;
    i   smallint;
begin
    select num_slots into v_n from pgfr_record.ring_config where singleton;

    execute $t$
        create table if not exists pgfr_record.activity_samples (
            sample_ts        int4  not null,
            pid              int4  not null,
            usename          text,
            application_name text,
            client_addr      inet,
            backend_type     text,
            state            text,
            wait_event_type  text,
            wait_event       text,
            backend_start    timestamptz,
            xact_start       timestamptz,
            query_start      timestamptz,
            state_change     timestamptz,
            query_preview    text,
            slot             smallint not null
        ) partition by list (slot)
    $t$;

    for i in 0..(v_n - 1) loop
        execute format(
            'create table if not exists pgfr_record.activity_samples_%s '
            'partition of pgfr_record.activity_samples for values in (%s)',
            i, i
        );
        execute format(
            'create index if not exists activity_samples_%s_ts_idx '
            'on pgfr_record.activity_samples_%s (sample_ts)',
            i, i
        );
    end loop;
end;
$$;

comment on table pgfr_record.activity_samples is
'Ring buffer v2: flat per-backend activity samples. One row per active session per tick. '
'Top 25 sessions by query age. Partitioned by LIST(slot); TRUNCATE on rotation. '
'Feeds archive_ring_samples() and flush_ring_to_aggregates(). Never DELETEd.';

--------------------------------------------------------------------------------
-- 12. lock_type_map: compact int → text mapping for lock_samples.lock_type
-- Keeps lock_samples rows narrow (smallint vs text).
--------------------------------------------------------------------------------

create table if not exists pgfr_record.lock_type_map (
    id       smallint primary key generated always as identity (start with 1),
    lock_type text not null unique
);

comment on table pgfr_record.lock_type_map is
'Lock type dictionary: maps smallint id -> lock type text. '
'Used to decode lock_samples.lock_type. Shared singleton, never truncated.';

insert into pgfr_record.lock_type_map (lock_type)
values
    ('relation'), ('extend'), ('frozenid'), ('page'), ('tuple'),
    ('transactionid'), ('virtualxid'), ('spectoken'), ('object'),
    ('userlock'), ('advisory'), ('applytransaction')
on conflict (lock_type) do nothing;

--------------------------------------------------------------------------------
-- 13. sample_ring() v2: also inserts into activity_samples
-- Adds activity sampling to the existing wait + lock sampling in sample_ring().
--------------------------------------------------------------------------------

create or replace function pgfr_record.sample_ring()
returns timestamptz
language plpgsql
as $$
declare
    v_slot              smallint;
    v_sample_ts         int4;
    v_captured_at       timestamptz;
    v_include_bg        bool;
    v_debug_logging     bool;
    v_rec               record;
    v_datid_rec         record;
    v_data              integer[];
    v_active_count      smallint;
    v_seen_waits        text[] := '{}';
    v_rows_inserted     int    := 0;
begin
    v_captured_at := clock_timestamp();
    v_sample_ts   := extract(epoch from (v_captured_at - pgfr_record.epoch()))::int4;
    v_slot        := pgfr_record.ring_current_slot();

    v_include_bg    := coalesce(pgfr_record._get_config('include_bg_workers', 'false')::bool, false);
    v_debug_logging := coalesce(pgfr_record._get_config('debug_logging', 'false')::bool, false);

    -- -------------------------------------------------------------------------
    -- read 1: register new wait events; walk pg_stat_activity once.
    -- -------------------------------------------------------------------------
    for v_rec in
        select
            sa.pid,
            sa.state,
            coalesce(sa.wait_event_type,
                case
                    when sa.state = 'active'                   then 'CPU*'
                    when sa.state like 'idle in transaction%'  then 'IdleTx'
                end
            ) as wait_type,
            coalesce(sa.wait_event,
                case
                    when sa.state = 'active'                   then 'CPU*'
                    when sa.state like 'idle in transaction%'  then 'IdleTx'
                end
            ) as wait_event,
            sa.backend_type,
            null::bigint as query_id   -- populated per-session via query_map on PG14+
        from pg_stat_activity sa
        where sa.state in ('active', 'idle in transaction', 'idle in transaction (aborted)')
          and (sa.backend_type = 'client backend'
           or (v_include_bg and sa.backend_type in (
                   'autovacuum worker', 'logical replication worker',
                   'parallel worker', 'background worker')))
          and sa.pid <> pg_backend_pid()
    loop
        if not (v_rec.state || '|' || v_rec.wait_type || '|' || v_rec.wait_event = any(v_seen_waits)) then
            v_seen_waits := v_seen_waits
                || (v_rec.state || '|' || v_rec.wait_type || '|' || v_rec.wait_event);
            if not exists (
                select from pgfr_record.wait_event_map
                where state = v_rec.state and type = v_rec.wait_type and event = v_rec.wait_event
            ) then
                perform pgfr_record._register_wait(v_rec.state, v_rec.wait_type, v_rec.wait_event);
            end if;
        end if;

        if v_debug_logging then
            raise log 'pgfr_record.sample_ring: pid=% state=% wait_type=% wait_event=% backend_type=% query_id=%',
                v_rec.pid, v_rec.state, v_rec.wait_type, v_rec.wait_event,
                v_rec.backend_type, coalesce(v_rec.query_id::text, '(null)');
        end if;
    end loop;

    -- -------------------------------------------------------------------------
    -- read 2: register query_ids into current slot's query_map (50k hard cap)
    -- query_id in pg_stat_activity requires PG14+; skip on PG13.
    -- -------------------------------------------------------------------------
    if (select current_setting('server_version_num')::int) >= 140000 then
    execute format(
        'insert into pgfr_record.query_map_%s (query_id) '
        'select distinct sa.query_id '
        'from pg_stat_activity sa '
        'where sa.query_id is not null '
        '  and sa.state in (''active'', ''idle in transaction'', ''idle in transaction (aborted)'') '
        '  and (sa.backend_type = ''client backend'' '
        '   or ($1 and sa.backend_type in ('
        '       ''autovacuum worker'', ''logical replication worker'', '
        '       ''parallel worker'', ''background worker''))) '
        '  and sa.pid <> pg_backend_pid() '
        '  and (select reltuples from pg_class '
        '       where oid = ''pgfr_record.query_map_%s''::regclass) < 50000 '
        'on conflict (query_id) do nothing',
        v_slot, v_slot
    ) using v_include_bg;
    end if; -- PG14+ query_id guard

    -- -------------------------------------------------------------------------
    -- reads 3+4: per-database wait encoding (unchanged from original)
    -- -------------------------------------------------------------------------
    for v_datid_rec in
        select distinct coalesce(sa.datid, 0::oid) as datid
        from pg_stat_activity sa
        where sa.state in ('active', 'idle in transaction', 'idle in transaction (aborted)')
          and (sa.backend_type = 'client backend'
           or (v_include_bg and sa.backend_type in (
                   'autovacuum worker', 'logical replication worker',
                   'parallel worker', 'background worker')))
          and sa.pid <> pg_backend_pid()
    loop
        begin
            execute format(
                'with snapshot as ( '
                '    select '
                '        wm.id as wait_id, '
                '        coalesce(m.id, 0) as map_id '
                '    from pg_stat_activity sa '
                '    join pgfr_record.wait_event_map wm '
                '         on wm.state = sa.state '
                '        and wm.type = coalesce(sa.wait_event_type, '
                '            case when sa.state = ''active'' then ''CPU*'' '
                '                 when sa.state like ''idle in transaction%%'' then ''IdleTx'' end) '
                '        and wm.event = coalesce(sa.wait_event, '
                '            case when sa.state = ''active'' then ''CPU*'' '
                '                 when sa.state like ''idle in transaction%%'' then ''IdleTx'' end) '
                '    left join pgfr_record.query_map_all m '
                '           on m.slot = %s::smallint and m.query_id = sa.query_id '
                '    where sa.state in (''active'', ''idle in transaction'', ''idle in transaction (aborted)'') '
                '      and (sa.backend_type = ''client backend'' '
                '       or ($1 and sa.backend_type in ( '
                '           ''autovacuum worker'', ''logical replication worker'', '
                '           ''parallel worker'', ''background worker''))) '
                '      and sa.pid <> pg_backend_pid() '
                '      and coalesce(sa.datid, 0::oid) = $2 '
                '), '
                'groups as ( '
                '    select '
                '        row_number() over (order by s.wait_id) as gnum, '
                '        array[(-s.wait_id)::integer, count(*)::integer] '
                '            || array_agg(s.map_id::integer) as group_arr '
                '    from snapshot s '
                '    group by s.wait_id '
                '), '
                'flat as ( '
                '    select array_agg(el order by g.gnum, u.ord) as data '
                '    from groups g, '
                '         lateral unnest(g.group_arr) with ordinality as u(el, ord) '
                '), '
                'backend_count as ( '
                '    select count(*)::smallint as cnt from snapshot '
                ') '
                'select f.data, bc.cnt from flat f, backend_count bc',
                v_slot
            ) into v_data, v_active_count using v_include_bg, v_datid_rec.datid;

            if v_data is not null and array_length(v_data, 1) >= 3 then
                insert into pgfr_record.wait_samples (sample_ts, datid, active_count, data, slot)
                values (v_sample_ts, v_datid_rec.datid, v_active_count, v_data, v_slot);
                v_rows_inserted := v_rows_inserted + 1;
            end if;

        exception when others then
            raise warning 'pgfr_record.sample_ring: error encoding sample for datid % [%]: %',
                v_datid_rec.datid, sqlstate, sqlerrm;
        end;
    end loop;

    -- -------------------------------------------------------------------------
    -- read 5: activity_samples — top 25 sessions by query age
    -- -------------------------------------------------------------------------
    begin
        execute format(
            'insert into pgfr_record.activity_samples_%s '
            '    (sample_ts, pid, usename, application_name, client_addr, '
            '     backend_type, state, wait_event_type, wait_event, '
            '     backend_start, xact_start, query_start, state_change, '
            '     query_preview, slot) '
            'select '
            '    $1, sa.pid, sa.usename, sa.application_name, sa.client_addr, '
            '    sa.backend_type, sa.state, sa.wait_event_type, sa.wait_event, '
            '    sa.backend_start, sa.xact_start, sa.query_start, sa.state_change, '
            '    left(sa.query, 500), $2::smallint '
            'from pg_stat_activity sa '
            'where sa.state in (''active'', ''idle in transaction'', ''idle in transaction (aborted)'') '
            '  and (sa.backend_type = ''client backend'' '
            '   or ($3 and sa.backend_type in ( '
            '       ''autovacuum worker'', ''logical replication worker'', '
            '       ''parallel worker'', ''background worker''))) '
            '  and sa.pid <> pg_backend_pid() '
            'order by sa.query_start asc nulls last '
            'limit 25',
            v_slot
        ) using v_sample_ts, v_slot, v_include_bg;
    exception when others then
        raise warning 'pgfr_record.sample_ring: activity_samples insert failed [%]: %', sqlstate, sqlerrm;
    end;

    return v_captured_at;
end;
$$;

comment on function pgfr_record.sample_ring() is
'Ring buffer v2 sampler: INSERT-based replacement for the UPDATE pattern in sample(). '
'Encodes wait events as integer[] arrays: [-wait_id, count, qmap_id, ...] per database. '
'Also inserts flat rows into activity_samples (top 25 sessions by query age). '
'Dual operation: existing sample() continues to work during migration. '
'Call via pg_cron at 1-minute cadence; use rotate_ring() on a slower schedule.';

--------------------------------------------------------------------------------
-- 14. flush_ring_to_aggregates() v2: reads new ring tables
-- Replaces reads from samples_ring/wait_samples_ring/lock_samples_ring
-- with reads from wait_samples, lock_samples, activity_samples (v2).
-- Decodes wait_samples integer[] via wait_event_map.
-- Uses ring_config to know the current slot; reads all slots (full ring window).
--------------------------------------------------------------------------------

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
    -- determine window: all data in ring since last flush
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
        return;
    end if;

    v_start_time := pgfr_record.epoch() + v_start_ts * interval '1 second';
    v_end_time   := pgfr_record.epoch() + v_end_ts   * interval '1 second';

    -- -------------------------------------------------------------------------
    -- wait event aggregates: decode integer[] via wait_event_map
    -- one group per (wait_event_map entry) per flush window
    -- -------------------------------------------------------------------------
    insert into pgfr_record.wait_event_aggregates (
        start_time, end_time, backend_type, wait_event_type, wait_event, state,
        sample_count, total_waiters, avg_waiters, max_waiters, pct_of_samples
    )
    with decoded as (
        -- extract (wait_id, count) pairs from each integer[] row
        -- format: [-wid, cnt, qmap_id, ...] repeated per wait group
        select
            ws.sample_ts,
            abs(ws.data[idx.i])::smallint             as wait_id,
            ws.data[idx.i + 1]::int                   as waiter_count
        from pgfr_record.wait_samples ws
        cross join lateral (
            select i
            from generate_subscripts(ws.data, 1) as i
            where ws.data[i] < 0          -- marker: negative = wait_event_map id
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
        wem.state        as backend_type,   -- state doubles as backend_type proxy
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

    -- -------------------------------------------------------------------------
    -- lock aggregates: decode lock_samples using lock_type_map
    -- -------------------------------------------------------------------------
    insert into pgfr_record.lock_aggregates (
        start_time, end_time, blocked_user, blocking_user, lock_type,
        locked_relation_oid, occurrence_count, max_duration, avg_duration, sample_query
    )
    select
        v_start_time,
        v_end_time,
        null as blocked_user,       -- lock_samples v2 stores pids not usernames
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

    -- -------------------------------------------------------------------------
    -- activity aggregates: from activity_samples (flat rows)
    -- -------------------------------------------------------------------------
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

    raise notice 'pgfr_record: Flushed ring buffer (% to %, % samples)',
        v_start_time, v_end_time, v_total_samples;
end;
$$;

comment on function pgfr_record.flush_ring_to_aggregates() is
'Ring buffer v2: flush wait_samples, lock_samples, activity_samples to durable aggregates. '
'Decodes wait_samples integer[] via wait_event_map. '
'Reads all ring slots since last flush (not slot-bounded). '
'Called every 5 minutes via pg_cron (pgfr_flush job).';

--------------------------------------------------------------------------------
-- 15. archive_ring_samples() v2: reads new ring tables
-- Drains wait_samples, lock_samples, activity_samples into archive tables.
-- Decodes lock_type via lock_type_map; wait events via wait_event_map.
-- Archive tables retain full-resolution data for forensic analysis.
--------------------------------------------------------------------------------

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
    v_activity_rows       int := 0;
    v_lock_rows           int := 0;
    v_wait_rows           int := 0;
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

    -- last archive watermark: max sample_ts already archived across all three tables
    select coalesce(greatest(
        (select extract(epoch from max(captured_at) - pgfr_record.epoch())::int4
         from pgfr_record.activity_samples_archive),
        (select extract(epoch from max(captured_at) - pgfr_record.epoch())::int4
         from pgfr_record.lock_samples_archive),
        (select extract(epoch from max(captured_at) - pgfr_record.epoch())::int4
         from pgfr_record.wait_samples_archive)
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

    if v_samples_to_archive = 0 then
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
        -- decode integer[] into one row per (sample_ts, wait_event)
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

    raise notice 'pgfr_record: Archived raw samples (% samples, % activity rows, % lock rows, % wait rows)',
        v_samples_to_archive, v_activity_rows, v_lock_rows, v_wait_rows;
end;
$$;

comment on function pgfr_record.archive_ring_samples() is
'Ring buffer v2: archive wait_samples, lock_samples, activity_samples to persistent archive tables. '
'Decodes wait_samples integer[] via wait_event_map. '
'Decodes lock_samples.lock_type via lock_type_map. '
'Archive cadence controlled by archive_sample_frequency_minutes config (default 15). '
'Called every 15 minutes via pg_cron (pgfr_archive job).';

--------------------------------------------------------------------------------
-- End of ring buffer v2 section
--------------------------------------------------------------------------------

