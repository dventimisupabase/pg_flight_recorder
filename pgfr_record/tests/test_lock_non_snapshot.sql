-- pgTAP test: lock collection must work when snapshot_based_collection = false
--
-- Bug: When snapshot_based = false, _fr_psa_snapshot temp table is never
-- created, but the lock collection JOIN unconditionally references it.
-- The EXCEPTION handler silently swallows the error, so sample() doesn't
-- crash — but sections_succeeded < sections_total because the lock
-- section fails.
--
-- Strategy: set snapshot_based_collection = false, call sample(),
-- verify all sections succeeded (sections_succeeded = sections_total).

\set ON_ERROR_STOP 1
set client_min_messages to warning;

select plan(3);

-- -------------------------------------------------------------------------
-- Test 1: sample() runs without error with snapshot_based = false
-- -------------------------------------------------------------------------
INSERT INTO pgfr_record.config (key, value, updated_at) VALUES ('snapshot_based_collection', 'false', now()) ON CONFLICT (key) DO UPDATE SET value = 'false', updated_at = now();

select lives_ok(
    $$SELECT pgfr_record.sample_ring()$$,
    'sample() executes without error when snapshot_based_collection = false'
);

-- -------------------------------------------------------------------------
-- Test 2: all sections succeeded (no silent failures)
-- -------------------------------------------------------------------------
-- Call sample() again and check that the collection_stats entry
-- has sections_succeeded = sections_total (no section silently failed)

do $$
declare
    v_ts timestamptz;
    v_stat record;
begin
    v_ts := pgfr_record.sample_ring();

    -- Get the most recent collection_stats entry
    select sections_total, sections_succeeded, success, error_message
    into v_stat
    from pgfr_record.collection_stats
    where collection_type = 'sample'
    order by started_at desc
    limit 1;

    if v_stat.sections_succeeded < v_stat.sections_total then
        raise exception 'Not all sections succeeded: %/% (lock collection likely failed on _fr_psa_snapshot)',
            v_stat.sections_succeeded, v_stat.sections_total;
    end if;

    perform set_config('test.sections_total', v_stat.sections_total::text, false);
    perform set_config('test.sections_succeeded', v_stat.sections_succeeded::text, false);
end $$;

select is(
    current_setting('test.sections_succeeded')::int,
    current_setting('test.sections_total')::int,
    'all sample() sections succeeded with snapshot_based = false (lock collection not silently failing)'
);

-- -------------------------------------------------------------------------
-- Test 3: sample() with snapshot_based = true also works (regression check)
-- -------------------------------------------------------------------------
INSERT INTO pgfr_record.config (key, value, updated_at) VALUES ('snapshot_based_collection', 'true', now()) ON CONFLICT (key) DO UPDATE SET value = 'true', updated_at = now();

do $$
declare
    v_ts timestamptz;
    v_stat record;
begin
    v_ts := pgfr_record.sample_ring();

    select sections_total, sections_succeeded
    into v_stat
    from pgfr_record.collection_stats
    where collection_type = 'sample'
    order by started_at desc
    limit 1;

    if v_stat.sections_succeeded < v_stat.sections_total then
        raise exception 'snapshot_based=true regression: %/% sections succeeded',
            v_stat.sections_succeeded, v_stat.sections_total;
    end if;
end $$;

select ok(true, 'sample() with snapshot_based = true still works (regression check)');

-- -------------------------------------------------------------------------
-- Cleanup
-- -------------------------------------------------------------------------
INSERT INTO pgfr_record.config (key, value, updated_at) VALUES ('snapshot_based_collection', 'true', now()) ON CONFLICT (key) DO UPDATE SET value = 'true', updated_at = now();

select * from finish();
