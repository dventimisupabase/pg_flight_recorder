-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

--------------------------------------------------------------------------------
-- Self-overhead budget (Issue #103).
--
-- The instrument reports its own perturbation: observer effect is part of the
-- error model, not an embarrassment to hide. Every figure here is
-- self-measured from the recorder's own tables at call time, in the same
-- figures of merit the recorder reports for everything else, so the budget
-- can be re-checked at any moment rather than trusted from a one-time
-- benchmark. The method column states exactly how each number is computed.
--------------------------------------------------------------------------------

create or replace function pgfr_analyze.self_overhead()
returns table (
    metric text,
    value  numeric,
    units  text,
    method text
)
language plpgsql
stable
as $$
begin
    return query
    select 'snapshot_ms_per_tick'::text,
           round(avg(cs.duration_ms)::numeric, 1),
           'milliseconds'::text,
           'avg(collection_stats.duration_ms) over successful, non-skipped snapshot runs in the last 24 hours; the cron job''s 10s statement_timeout is the hard per-tick ceiling'::text
    from pgfr_record.collection_stats cs
    where cs.collection_type = 'snapshot'
      and cs.success and not cs.skipped and cs.completed_at is not null
      and cs.started_at > now() - interval '24 hours';

    return query
    select 'sample_ms_per_tick'::text,
           round(avg(cs.duration_ms)::numeric, 1),
           'milliseconds'::text,
           'avg(collection_stats.duration_ms) over successful, non-skipped ring sampler runs in the last 24 hours; the cron job''s 500ms statement_timeout is the hard per-tick ceiling'::text
    from pgfr_record.collection_stats cs
    where cs.collection_type = 'sample'
      and cs.success and not cs.skipped and cs.completed_at is not null
      and cs.started_at > now() - interval '24 hours';

    return query
    select 'recorder_block_share'::text,
           round(avg(cf.recorder_overhead_fraction)::numeric, 6),
           'fraction'::text,
           'avg(consumption_flows.recorder_overhead_fraction) over the last 24 hours: block traffic against the recorder''s own schema over total block demand, both from the same tick deltas'::text
    from pgfr_record.consumption_flows cf
    where cf.captured_at > now() - interval '24 hours';

    return query
    select 'storage_bytes'::text,
           sum(pg_total_relation_size(c.oid))::numeric,
           'bytes'::text,
           'sum(pg_total_relation_size) over ordinary and materialized relations in the pgfr_record and pgfr_analyze schemas (includes indexes and TOAST); bounded by the retention settings, so this converges rather than growing without limit'::text
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('pgfr_record', 'pgfr_analyze')
      and c.relkind in ('r', 'm');

    -- The recorder's queries are part of the population it samples: quantify
    -- the share. Guarded because pg_stat_statements is optional.
    if exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
        return query
        execute $q$
            select 'pgss_time_share'::text,
                   round((sum(s.total_exec_time) filter (where s.query ilike '%pgfr\_%')
                          / nullif(sum(s.total_exec_time), 0))::numeric, 6),
                   'fraction'::text,
                   'pgfr-attributed total_exec_time over all total_exec_time in pg_stat_statements since its last reset (statements whose text references a pgfr_ schema)'::text
            from pg_stat_statements s
        $q$;
    end if;
end;
$$;

comment on function pgfr_analyze.self_overhead() is
'Self-measured observer-effect budget (Issue #103; see STATISTICS.md): the recorder''s own per-tick collection time, buffer-traffic share, storage footprint, and share of pg_stat_statements execution time, each computed at call time from the recorder''s own tables with the method stated per row. A row''s value is NULL when the last 24 hours hold no evidence for it (e.g. a fresh install).
Output columns:
  metric: [dimension] [text] Which overhead figure the row carries: snapshot_ms_per_tick, sample_ms_per_tick, recorder_block_share, storage_bytes, or pgss_time_share (the last only when pg_stat_statements is installed).
  value: [derived] [mixed] The measured figure; units vary by metric (see the units column). NULL when no evidence exists in the measurement window.
  units: [dimension] [text] Units of value for this row: milliseconds, fraction (0-1), or bytes.
  method: [dimension] [text] Exactly how the figure is computed, stated so it can be re-run by hand; the measurement window and any hard ceilings are named here.';
