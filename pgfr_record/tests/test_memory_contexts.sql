-- pgTAP test: memory context collection (pg_backend_memory_contexts, PG 14+)
--
-- Verifies:
--   - Schema: dictionary, ring partitions, aggregates, archive
--   - Config: three new keys, all default-off
--   - Dictionary: _register_memory_context_name is idempotent and race-safe shape
--   - Sampling: PG 13 no-op, disabled no-op, enabled PG 14+ inserts self contexts
--   - Rotation: memory_context_samples partition truncated on rotate_ring()
--   - Flush: memory_context_aggregates populated
--   - Archive: memory_context_samples_archive drained

\set ON_ERROR_STOP 1
set client_min_messages to warning;

select plan(22);

-- =========================================================================
-- 1. Schema (8 tests)
-- =========================================================================

select has_table('pgfr_record', 'memory_context_name_map',
    'Dictionary table exists');

select has_table('pgfr_record', 'memory_context_samples',
    'Ring parent table exists');

select has_table('pgfr_record', 'memory_context_samples_0',
    'Ring partition _0 exists');

select has_table('pgfr_record', 'memory_context_samples_1',
    'Ring partition _1 exists');

select has_table('pgfr_record', 'memory_context_samples_2',
    'Ring partition _2 exists');

select has_table('pgfr_record', 'memory_context_aggregates',
    'Aggregate table exists');

select has_table('pgfr_record', 'memory_context_samples_archive',
    'Archive table exists');

select has_function('pgfr_record', 'sample_memory_contexts', array[]::text[],
    'Sampling function exists');

-- =========================================================================
-- 2. Config defaults (2 tests) — sampling off by default
-- =========================================================================

select is(
    (select value from pgfr_record.config where key = 'memory_context_sampling_enabled'),
    'false',
    'Sampling default-disabled'
);

-- PG 14+ guard: sampling function returns 0 when disabled
select is(
    pgfr_record.sample_memory_contexts(),
    0,
    'Disabled: sample_memory_contexts() returns 0 rows'
);

-- =========================================================================
-- 3. Dictionary behavior (3 tests)
-- =========================================================================

do $$
declare
    v_id1 smallint;
    v_id2 smallint;
    v_id3 smallint;
begin
    v_id1 := pgfr_record._register_memory_context_name('TopMemoryContext');
    v_id2 := pgfr_record._register_memory_context_name('TopMemoryContext');
    v_id3 := pgfr_record._register_memory_context_name('CacheMemoryContext');

    perform set_config('test.mc_id1', v_id1::text, false);
    perform set_config('test.mc_id2', v_id2::text, false);
    perform set_config('test.mc_id3', v_id3::text, false);
end $$;

select is(
    current_setting('test.mc_id1')::int,
    current_setting('test.mc_id2')::int,
    'Repeated name returns same id (idempotent)'
);

select isnt(
    current_setting('test.mc_id1')::int,
    current_setting('test.mc_id3')::int,
    'Distinct names get distinct ids'
);

select ok(
    current_setting('test.mc_id1')::int > 0,
    'Generated ids are positive smallints'
);

-- =========================================================================
-- 4. Sampling behavior when enabled (4 tests)
-- =========================================================================

-- Enable sampling
update pgfr_record.config
   set value = 'true'
 where key = 'memory_context_sampling_enabled';

-- Run sampler. On PG < 14 this is a no-op (returns 0). On PG 14+ we expect
-- self-backend contexts to be inserted.
do $$
declare
    v_before bigint;
    v_after  bigint;
    v_pg     int;
    v_inserted int;
begin
    select count(*) into v_before from pgfr_record.memory_context_samples;
    v_pg := current_setting('server_version_num')::int;

    v_inserted := pgfr_record.sample_memory_contexts();

    select count(*) into v_after from pgfr_record.memory_context_samples;

    perform set_config('test.mc_before', v_before::text, false);
    perform set_config('test.mc_after', v_after::text, false);
    perform set_config('test.mc_inserted', v_inserted::text, false);
    perform set_config('test.mc_is_pg14_plus', case when v_pg >= 140000 then '1' else '0' end, false);
end $$;

-- PG14+: rows inserted. PG13: zero rows (function is a no-op).
select ok(
    case when current_setting('test.mc_is_pg14_plus') = '1'
         then current_setting('test.mc_after')::bigint > current_setting('test.mc_before')::bigint
         else current_setting('test.mc_inserted')::int = 0
    end,
    'Enabled sampler inserts rows on PG 14+, no-op on PG 13'
);

-- PG14+: pid should match our backend (self-sampling)
select ok(
    case when current_setting('test.mc_is_pg14_plus') = '1'
         then exists (
             select 1 from pgfr_record.memory_context_samples
             where pid = pg_backend_pid()
         )
         else true  -- trivially pass on PG 13
    end,
    'Self-sampled rows carry pid = pg_backend_pid() on PG 14+'
);

-- Dictionary is populated after sampling (PG14+)
select ok(
    case when current_setting('test.mc_is_pg14_plus') = '1'
         then (select count(*) from pgfr_record.memory_context_name_map) > 0
         else true
    end,
    'Dictionary populated after sampling on PG 14+'
);

-- All inserted rows have a valid name_id (FK-style consistency)
select is(
    (select count(*)::int
     from pgfr_record.memory_context_samples s
     left join pgfr_record.memory_context_name_map m on m.id = s.name_id
     where m.id is null),
    0,
    'All samples point to valid dictionary entries'
);

-- =========================================================================
-- 5. Rotation truncates memory_context_samples partition (1 test)
-- =========================================================================

do $$
declare
    v_current   smallint;
    v_num_slots smallint;
    v_next_slot smallint;
    v_truncate_slot smallint;
begin
    select current_slot, num_slots
      into v_current, v_num_slots
      from pgfr_record.ring_config where singleton;

    v_next_slot     := (v_current + 1) % v_num_slots;
    v_truncate_slot := (v_next_slot + 1) % v_num_slots;

    -- canary row in the slot about to be truncated
    execute format(
        'insert into pgfr_record.memory_context_samples_%s '
        '(sample_ts, pid, name_id, slot) values (999999, 1, 1, %s)',
        v_truncate_slot, v_truncate_slot
    );

    update pgfr_record.ring_config
       set rotated_at = now() - interval '3 hours'
     where singleton;

    perform set_config('test.mc_truncate_slot', v_truncate_slot::text, false);
end $$;

select matches(
    pgfr_record.rotate_ring(),
    '^rotated',
    'rotate_ring() rotated (for memory context truncate check)'
);

select is(
    (select count(*)::int
       from pgfr_record.memory_context_samples
      where slot = current_setting('test.mc_truncate_slot')::smallint
        and sample_ts = 999999),
    0,
    'memory_context_samples canary cleared by rotate_ring()'
);

-- =========================================================================
-- 6. Flush emits memory_context_aggregates (2 tests)
-- =========================================================================

-- Ensure at least one sample exists post-rotation for flush to consume
select pgfr_record.sample_memory_contexts();

do $$
declare
    v_before bigint;
    v_after  bigint;
    v_pg14   bool;
begin
    v_pg14 := current_setting('server_version_num')::int >= 140000;

    select count(*) into v_before from pgfr_record.memory_context_aggregates;
    perform pgfr_record.flush_ring_to_aggregates();
    select count(*) into v_after from pgfr_record.memory_context_aggregates;

    perform set_config('test.mc_agg_before', v_before::text, false);
    perform set_config('test.mc_agg_after',  v_after::text,  false);
    perform set_config('test.mc_pg14',       case when v_pg14 then '1' else '0' end, false);
end $$;

select ok(
    case when current_setting('test.mc_pg14') = '1'
         then current_setting('test.mc_agg_after')::bigint >= current_setting('test.mc_agg_before')::bigint
         else true
    end,
    'flush_ring_to_aggregates() does not error and rows are non-decreasing'
);

-- Aggregate rows must have positive byte totals when present
select ok(
    not exists (
        select 1 from pgfr_record.memory_context_aggregates
        where sum_total_bytes is not null and sum_total_bytes < 0
    ),
    'Aggregated sum_total_bytes is never negative'
);

-- =========================================================================
-- 7. Archive drains to memory_context_samples_archive (1 test)
-- =========================================================================

-- Force archive cadence window to always be due
update pgfr_record.config set value = '0'
 where key = 'archive_sample_frequency_minutes';

-- Insert a synthetic sample so the archive has something to drain
do $$
declare
    v_slot smallint;
begin
    v_slot := pgfr_record.ring_current_slot();
    -- ensure a dictionary entry exists
    perform pgfr_record._register_memory_context_name('TestArchiveCtx');

    execute format(
        'insert into pgfr_record.memory_context_samples_%s '
        '(sample_ts, pid, backend_type, name_id, level, total_bytes, used_bytes, free_bytes, slot) '
        'select $1, 12345, ''test_backend'', m.id, 0, 1024, 512, 512, $2 '
        'from pgfr_record.memory_context_name_map m where m.name = ''TestArchiveCtx''',
        v_slot
    ) using extract(epoch from now() - pgfr_record.epoch())::int4, v_slot;
end $$;

select pgfr_record.archive_ring_samples();

select ok(
    exists (
        select 1 from pgfr_record.memory_context_samples_archive
        where context_name = 'TestArchiveCtx' and pid = 12345
    ),
    'archive_ring_samples() drained memory_context row to archive'
);

-- Restore archive cadence to avoid leaking setting into other tests
update pgfr_record.config set value = '15'
 where key = 'archive_sample_frequency_minutes';

-- Restore sampling to off (matches default)
update pgfr_record.config set value = 'false'
 where key = 'memory_context_sampling_enabled';

select * from finish();
