-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

--------------------------------------------------------------------------------
-- Coverage and gap accounting (Issue #100).
--
-- Absence of samples and absence of activity are different facts. Both cron
-- collectors run at a fixed one-minute cadence ('* * * * *', hardcoded in
-- enable(); sample_interval_seconds is inert, see Issue #106), so the expected
-- tick count for any window is well-defined: one tick per minute boundary.
-- coverage() reports expected vs observed ticks per collector;
-- coverage_gaps() lists each contiguous run of missing ticks with an
-- attributed reason. Attribution order, most to least specific:
--
--   retention_horizon  the tick predates the oldest evidence the recorder
--                      still retains for that collector (rotated out of the
--                      ring, expired from retention, or the recorder was not
--                      yet collecting)
--   circuit_breaker /  a collection_stats skip row covers the tick's minute
--   load_shedding      (enumerated skip_kind; legacy prose classified via
--                      pgfr_record._skip_kind())
--   restart            the tick falls in the unobserved run leading into
--                      pg_postmaster_start_time(): the server was plausibly
--                      down. collection_stats is UNLOGGED, so a crash also
--                      destroys the skip evidence; post-crash gaps land here
--                      rather than claiming clean coverage. Event-based
--                      restart detection is Issue #101.
--   cron_inactive      the collector's cron job is currently missing or
--                      deactivated (cron.job may be unreadable on managed
--                      platforms; attribution degrades to unknown)
--   unknown            no evidence either way
--
-- The most dangerous gaps are informative ones: the circuit breaker and load
-- shedding skip collection precisely when the system is under stress, so
-- missingness correlates with the states of interest (MNAR). Consumers must
-- surface those attributions, never interpolate over them. See STATISTICS.md.
--------------------------------------------------------------------------------

-- Reads a pgfr cron job's active flag; NULL when cron.job is missing or not
-- readable (managed platforms), so callers can decline to attribute.
create or replace function pgfr_analyze._cron_job_active(p_jobname text)
returns boolean
language plpgsql
stable
as $$
declare
    v_active boolean;
begin
    select active into v_active from cron.job where jobname = p_jobname;
    return coalesce(v_active, false);   -- job missing entirely = not firing
exception when others then
    return null;                        -- cron.job unreadable: cannot attribute
end
$$;

comment on function pgfr_analyze._cron_job_active(text) is
'Active flag of a pgfr cron job, false when the job is missing, NULL when cron.job is inaccessible. Internal helper for coverage gap attribution.';

-- Internal per-tick grid: one row per (collector, expected minute tick) with
-- the observation flag and, for missing ticks, the attributed reason.
create or replace function pgfr_analyze._coverage_ticks(
    p_start_time timestamptz,
    p_end_time   timestamptz
)
returns table (
    collector         text,
    tick              timestamptz,
    observed          boolean,
    attributed_reason text
)
language sql
stable
as $$
with bounds as (
    select p_start_time              as w_start,
           least(p_end_time, now())  as w_end,
           pg_postmaster_start_time() as pm_start
),
ticks as (
    -- expected minute-aligned ticks in [w_start, w_end); future ticks are not
    -- expected, hence the least(..., now()) clamp in bounds
    select gs as tick
    from bounds b
    cross join lateral generate_series(
        date_trunc('minute', b.w_start)
            + case when date_trunc('minute', b.w_start) < b.w_start
                   then interval '1 minute' else interval '0 minutes' end,
        b.w_end,
        interval '1 minute') gs
    where gs < b.w_end
),
collectors as (
    -- stats_type maps a collector to its collection_stats.collection_type;
    -- consumption rides the pgfr_snapshot job, so it inherits snapshot skips
    select * from (values
        ('sample',      'sample'),
        ('snapshot',    'snapshot'),
        ('consumption', 'snapshot')
    ) as c(collector, stats_type)
),
observed as (
    -- observed ticks per collector, truncated to the minute so cron jitter
    -- (a sample landing a second or two into the minute) still matches
    select 'sample'::text as collector,
           date_trunc('minute', pgfr_record.epoch() + ws.sample_ts * interval '1 second') as m
    from pgfr_record.wait_samples ws, bounds b
    where ws.sample_ts >= extract(epoch from (b.w_start - pgfr_record.epoch()))::int4
      and ws.sample_ts <  extract(epoch from (b.w_end   - pgfr_record.epoch()))::int4
    group by 2
    union all
    select 'snapshot', date_trunc('minute', s.captured_at)
    from pgfr_record.snapshots s, bounds b
    where s.captured_at >= b.w_start and s.captured_at < b.w_end
    group by 2
    union all
    select 'consumption', date_trunc('minute', cs.captured_at)
    from pgfr_record.consumption_snapshots_v2 cs, bounds b
    where cs.captured_at >= b.w_start and cs.captured_at < b.w_end
      and cs.datname = current_database()
    group by 2
),
floors as (
    -- oldest retained evidence per collector; nominal policy floor when the
    -- table is empty. Ticks older than this are unknowable, not merely absent.
    select 'sample'::text as collector,
           coalesce(
               (select pgfr_record.epoch() + min(ws.sample_ts) * interval '1 second'
                from pgfr_record.wait_samples ws),
               now() - (select rc.num_slots * rc.rotation_period
                        from pgfr_record.ring_config rc where rc.singleton)
           ) as floor_ts
    union all
    select 'snapshot',
           coalesce(
               (select min(s.captured_at) from pgfr_record.snapshots s),
               now() - make_interval(days => coalesce(
                   (select c.value::int from pgfr_record.config c
                    where c.key = 'retention_snapshots_days'), 30))
           )
    union all
    select 'consumption',
           coalesce(
               (select min(cs.captured_at) from pgfr_record.consumption_snapshots_v2 cs
                where cs.datname = current_database()),
               now() - make_interval(days => coalesce(
                   (select c.value::int from pgfr_record.config c
                    where c.key = 'retention_snapshots_days'), 30))
           )
),
skips as (
    select date_trunc('minute', cs.started_at) as m,
           cs.collection_type as stats_type,
           coalesce(cs.skip_kind, pgfr_record._skip_kind(cs.skipped_reason)) as kind
    from pgfr_record.collection_stats cs, bounds b
    where cs.skipped
      and cs.started_at >= b.w_start and cs.started_at < b.w_end
),
grid as (
    select c.collector, c.stats_type, t.tick, (o.m is not null) as observed
    from collectors c
    cross join ticks t
    left join observed o on o.collector = c.collector and o.m = t.tick
),
last_obs as (
    -- newest observed tick before the postmaster start, per collector: the
    -- unobserved run between it and pm_start is the plausible down window
    select g.collector,
           max(g.tick) filter (where g.observed and g.tick < b.pm_start) as last_before_pm
    from grid g, bounds b
    group by 1
)
select g.collector,
       g.tick,
       g.observed,
       case
           when g.observed then null
           when g.tick < f.floor_ts then 'retention_horizon'
           when sk.kind is not null then sk.kind
           when g.tick < b.pm_start
                and (lo.last_before_pm is null or g.tick > lo.last_before_pm)
               then 'restart'
           when pgfr_analyze._cron_job_active(
                    case g.collector when 'sample' then 'pgfr_sample_ring'
                                     else 'pgfr_snapshot' end) is false
               then 'cron_inactive'
           else 'unknown'
       end as attributed_reason
from grid g
join floors f   on f.collector = g.collector
join last_obs lo on lo.collector = g.collector
cross join bounds b
left join lateral (
    select s.kind from skips s
    where s.stats_type = g.stats_type and s.m = g.tick
    limit 1
) sk on true
$$;

comment on function pgfr_analyze._coverage_ticks(timestamptz, timestamptz) is
'Internal per-tick coverage grid: one row per (collector, expected minute tick) with observation flag and, for missing ticks, the attributed reason. Backs coverage() and coverage_gaps().';

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

create or replace function pgfr_analyze.coverage(
    p_start_time timestamptz,
    p_end_time   timestamptz
)
returns table (
    collector        text,
    expected_samples integer,
    observed_samples integer,
    coverage_ratio   numeric
)
language sql
stable
as $$
select t.collector,
       count(*)::int                              as expected_samples,
       count(*) filter (where t.observed)::int    as observed_samples,
       round(count(*) filter (where t.observed)::numeric / nullif(count(*), 0), 3)
                                                  as coverage_ratio
from pgfr_analyze._coverage_ticks(p_start_time, p_end_time) t
group by t.collector
order by case t.collector when 'sample' then 1 when 'snapshot' then 2 else 3 end
$$;

comment on function pgfr_analyze.coverage(timestamptz, timestamptz) is
'Expected vs observed collection ticks per collector for a window, at the fixed one-minute cadence. Absence of samples is not absence of activity: check coverage_gaps() for what the missing ticks mean, and see STATISTICS.md for the error model. Returns zero rows when the window contains no expected ticks.
Output columns:
  collector: [dimension] [text] Which collector the row describes: sample (ring sampler), snapshot, or consumption (rides the pgfr_snapshot job).
  expected_samples: [derived] [count] Minute-aligned ticks in the window (clamped at now()); the denominator of coverage_ratio.
  observed_samples: [derived] [count] Expected ticks for which retained evidence exists (ring samples, snapshot rows, or consumption rows in the tick''s minute); the numerator of coverage_ratio.
  coverage_ratio: [derived] [fraction] observed_samples over expected_samples, 0 to 1; NULL when no ticks were expected.';

create or replace function pgfr_analyze.coverage(p_interval interval)
returns table (
    collector        text,
    expected_samples integer,
    observed_samples integer,
    coverage_ratio   numeric
)
language sql
stable
as $$
select * from pgfr_analyze.coverage(now() - p_interval, now())
$$;

comment on function pgfr_analyze.coverage(interval) is
'Interval convenience overload of coverage(start, end); see that function for output semantics.';

create or replace function pgfr_analyze.coverage_gaps(
    p_start_time timestamptz,
    p_end_time   timestamptz
)
returns table (
    collector         text,
    gap_start         timestamptz,
    gap_end           timestamptz,
    duration          interval,
    attributed_reason text
)
language sql
stable
as $$
with missing as (
    select t.collector, t.tick, t.attributed_reason,
           t.tick - row_number() over (
               partition by t.collector, t.attributed_reason order by t.tick
           ) * interval '1 minute' as island
    from pgfr_analyze._coverage_ticks(p_start_time, p_end_time) t
    where not t.observed
)
select m.collector,
       min(m.tick)                                as gap_start,
       max(m.tick) + interval '1 minute'          as gap_end,
       max(m.tick) + interval '1 minute' - min(m.tick) as duration,
       m.attributed_reason
from missing m
group by m.collector, m.attributed_reason, m.island
order by 1, 2
$$;

comment on function pgfr_analyze.coverage_gaps(timestamptz, timestamptz) is
'Contiguous runs of missing collection ticks in a window, one row per gap per collector, each with an attributed reason. Gaps attributed to circuit_breaker or load_shedding are informative missingness: collection was skipped because the system was under stress, so absence of samples there is not absence of activity (see STATISTICS.md).
Output columns:
  collector: [dimension] [text] Which collector the gap belongs to: sample, snapshot, or consumption.
  gap_start: [dimension] [timestamp] First missing minute tick of the gap, inclusive.
  gap_end: [dimension] [timestamp] End of the gap, exclusive (the minute after the last missing tick).
  duration: [derived] [duration] gap_end minus gap_start; one minute per missing tick.
  attributed_reason: [derived] [text] Why the ticks are missing: retention_horizon (predates oldest retained evidence), circuit_breaker or load_shedding (skip evidence in collection_stats), restart (unobserved run leading into pg_postmaster_start_time()), cron_inactive (job missing or deactivated), or unknown.';

create or replace function pgfr_analyze.coverage_gaps(p_interval interval)
returns table (
    collector         text,
    gap_start         timestamptz,
    gap_end           timestamptz,
    duration          interval,
    attributed_reason text
)
language sql
stable
as $$
select * from pgfr_analyze.coverage_gaps(now() - p_interval, now())
$$;

comment on function pgfr_analyze.coverage_gaps(interval) is
'Interval convenience overload of coverage_gaps(start, end); see that function for output semantics.';
