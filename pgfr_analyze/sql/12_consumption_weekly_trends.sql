-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

--------------------------------------------------------------------------------
-- Consumption trend engine, 90-day window, phases B and C of 4 (Issue #92).
--
-- _refresh_consumption_trends_weekly() is a genuine sibling to
-- _refresh_consumption_trends() (see 11_consumption_trends.sql), not a
-- parameterized rewrite of it -- exactly what that function's own comments
-- already committed to when #83 was built. That function's Theil-Sen/
-- changepoint logic already had several real bugs caught only by testing (a
-- count(*) miscount, Postgres's regr_r2 returning 1.0 instead of NULL/NaN for
-- zero-variance input, a sparkline arithmetic precision bug, missing
-- classification text). Generalizing it to handle two grains in one pass
-- risks destabilizing already-working, already-well-tested code for the sake
-- of avoiding some duplication.
--
-- Phase C adds the composition-drift guard at this grain, the same way and
-- reusing the same _pct_shift_exceeds() primitive as the daily engine: two
-- FIXED halves of the window (6 weeks vs. 6 weeks, i.e. the same
-- v_as_of_date - v_window_days/2 split point the daily engine uses, just
-- with v_window_days=84), not a searched split -- workload shape is a
-- property of the window, not of any one metric, so one flag applies to
-- every metric's row for that window. Same ordering rule too: composition
-- only overrides a *detected* movement (insufficient_data -> stable ->
-- composition -> step/drift), never relabels an already-stable metric.
--------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. consumption_weekly_metric_series — long-format unpivot of the 8 basket
--    metrics from pgfr_record.consumption_weekly_flows, mirroring
--    consumption_metric_series one tier up.
-- ---------------------------------------------------------------------------
create or replace view pgfr_analyze.consumption_weekly_metric_series as
select week_end_date, datname, 'blocks_per_row_returned'::text as metric_name, blocks_per_row_returned as value
from pgfr_record.consumption_weekly_flows
union all
select week_end_date, datname, 'wal_bytes_per_row_mutated', wal_bytes_per_row_mutated
from pgfr_record.consumption_weekly_flows
union all
select week_end_date, datname, 'temp_bytes_per_xact', temp_bytes_per_xact
from pgfr_record.consumption_weekly_flows
union all
select week_end_date, datname, 'fpi_fraction', fpi_fraction
from pgfr_record.consumption_weekly_flows
union all
select week_end_date, datname, 'ckpt_requested_fraction', ckpt_requested_fraction
from pgfr_record.consumption_weekly_flows
union all
select week_end_date, datname, 'rollback_fraction', rollback_fraction
from pgfr_record.consumption_weekly_flows
union all
select week_end_date, datname, 'autovacuum_write_share', autovacuum_write_share
from pgfr_record.consumption_weekly_flows
union all
select week_end_date, datname, 'cache_hit_fraction', cache_hit_fraction
from pgfr_record.consumption_weekly_flows;

comment on view pgfr_analyze.consumption_weekly_metric_series is
'Long-format (week_end_date, datname, metric_name, value) unpivot of '
'pgfr_record.consumption_weekly_flows'' 8 basket metrics, mirroring '
'consumption_metric_series one tier up. See Issue #92.';

-- ---------------------------------------------------------------------------
-- 2. _refresh_consumption_trends_weekly() — always recomputes and upserts
--    today's row for every (datname, basket metric) combination, 84-day
--    (12-week) window on weekly-aggregated points. Reuses the same
--    consumption_trends table (window_days = 84 distinguishes these rows
--    from the daily engine's window_days = 28) and the same
--    consumption_trend_min_r2 / consumption_trend_step_r2_margin thresholds
--    -- those are generic statistical properties, not grain-specific.
--    consumption_trend_min_weeks (default 8, matching Issue #83's own
--    "≥56 days before seasonal comparisons") is this window's own
--    minimum-data gate, the weekly analogue of consumption_trend_min_days.
-- ---------------------------------------------------------------------------
create or replace function pgfr_analyze._refresh_consumption_trends_weekly()
returns void
language plpgsql as $$
declare
    v_as_of_date      date := current_date;
    v_window_days     constant integer := 84;
    v_basket_version  constant integer := 1;
    v_min_weeks       integer;
    v_min_r2          numeric;
    v_step_r2_margin  numeric;
    v_shape_guard_pct numeric;
begin
    v_min_weeks       := coalesce(pgfr_record._get_config('consumption_trend_min_weeks', '8')::integer, 8);
    v_min_r2          := coalesce(pgfr_record._get_config('consumption_trend_min_r2', '0.3')::numeric, 0.3);
    v_step_r2_margin  := coalesce(pgfr_record._get_config('consumption_trend_step_r2_margin', '0.15')::numeric, 0.15);
    v_shape_guard_pct := coalesce(pgfr_record._get_config('consumption_trend_shape_guard_pct', '25')::numeric, 25);

    with window_points as (
        select
            s.datname, s.metric_name, s.week_end_date, s.value,
            (s.week_end_date - date '1970-01-01')::numeric as day_offset
        from pgfr_analyze.consumption_weekly_metric_series s
        where s.week_end_date > v_as_of_date - v_window_days
          and s.week_end_date <= v_as_of_date
          and s.value is not null
    ),
    all_combos as (
        select distinct r.datname, m.metric_name
        from pgfr_record.consumption_daily_rollups r
        cross join (values
            ('blocks_per_row_returned'), ('wal_bytes_per_row_mutated'),
            ('temp_bytes_per_xact'),     ('fpi_fraction'),
            ('ckpt_requested_fraction'), ('rollback_fraction'),
            ('autovacuum_write_share'),  ('cache_hit_fraction')
        ) as m(metric_name)
    ),
    -- Workload-shape guard (see 11_consumption_trends.sql's shape_halves for
    -- the daily-grain original): two FIXED halves of the window, not a
    -- searched split. At 84 days that's 6 weeks vs. 6 weeks.
    shape_halves as (
        select
            f.datname,
            count(*) as sample_count,
            avg(f.read_write_tuple_ratio) filter (where f.week_end_date <= v_as_of_date - v_window_days / 2) as rwtr_before,
            avg(f.read_write_tuple_ratio) filter (where f.week_end_date >  v_as_of_date - v_window_days / 2) as rwtr_after,
            avg(f.xact_per_s)             filter (where f.week_end_date <= v_as_of_date - v_window_days / 2) as xps_before,
            avg(f.xact_per_s)             filter (where f.week_end_date >  v_as_of_date - v_window_days / 2) as xps_after,
            avg(f.rows_returned_per_xact) filter (where f.week_end_date <= v_as_of_date - v_window_days / 2) as rrpx_before,
            avg(f.rows_returned_per_xact) filter (where f.week_end_date >  v_as_of_date - v_window_days / 2) as rrpx_after,
            avg(f.rows_mutated_per_xact)  filter (where f.week_end_date <= v_as_of_date - v_window_days / 2) as rmpx_before,
            avg(f.rows_mutated_per_xact)  filter (where f.week_end_date >  v_as_of_date - v_window_days / 2) as rmpx_after,
            avg(f.db_size_bytes)          filter (where f.week_end_date <= v_as_of_date - v_window_days / 2) as size_before,
            avg(f.db_size_bytes)          filter (where f.week_end_date >  v_as_of_date - v_window_days / 2) as size_after
        from pgfr_record.consumption_weekly_flows f
        where f.week_end_date > v_as_of_date - v_window_days
          and f.week_end_date <= v_as_of_date
        group by f.datname
    ),
    composition_flag as (
        select
            datname,
            (
                sample_count >= v_min_weeks
                and (
                    pgfr_analyze._pct_shift_exceeds(rwtr_before, rwtr_after, v_shape_guard_pct)
                    or pgfr_analyze._pct_shift_exceeds(xps_before, xps_after, v_shape_guard_pct)
                    or pgfr_analyze._pct_shift_exceeds(rrpx_before, rrpx_after, v_shape_guard_pct)
                    or pgfr_analyze._pct_shift_exceeds(rmpx_before, rmpx_after, v_shape_guard_pct)
                    or pgfr_analyze._pct_shift_exceeds(size_before, size_after, v_shape_guard_pct)
                )
            ) as composition_change
        from shape_halves
    ),
    group_stats as (
        select
            datname, metric_name,
            count(*) as sample_count,
            percentile_cont(0.5) within group (order by value) as median_value,
            -- See 11_consumption_trends.sql's group_stats comment: regr_r2
            -- returns 1.0, not NULL/NaN, for a zero-variance series.
            nullif(regr_r2(value, day_offset), 'nan'::double precision) as r2_line,
            (sum(value * value) - power(sum(value), 2) / nullif(count(*), 0)) as tss
        from window_points
        group by datname, metric_name
    ),
    pairwise_slopes as (
        select
            a.datname, a.metric_name,
            (b.value - a.value) / (b.day_offset - a.day_offset) as slope
        from window_points a
        join window_points b
          on b.datname = a.datname and b.metric_name = a.metric_name
         and b.day_offset > a.day_offset
    ),
    slope_calc as (
        select datname, metric_name,
               percentile_cont(0.5) within group (order by slope) as median_slope
        from pairwise_slopes
        group by datname, metric_name
    ),
    running as (
        select
            datname, metric_name, week_end_date,
            count(*)         over w as running_n,
            sum(value)       over w as running_sum,
            sum(value*value) over w as running_sumsq,
            count(*)         over (partition by datname, metric_name) as total_n,
            sum(value)       over (partition by datname, metric_name) as total_sum,
            sum(value*value) over (partition by datname, metric_name) as total_sumsq
        from window_points
        window w as (partition by datname, metric_name order by week_end_date)
    ),
    split_r2 as (
        select
            datname, metric_name, week_end_date as split_date,
            case
                when (total_sumsq - (total_sum * total_sum) / nullif(total_n, 0)) is null
                  or (total_sumsq - (total_sum * total_sum) / nullif(total_n, 0)) = 0
                then null
                else 1 - (
                    (running_sumsq - (running_sum * running_sum) / nullif(running_n, 0))
                    + ((total_sumsq - running_sumsq) - power(total_sum - running_sum, 2) / nullif(total_n - running_n, 0))
                ) / (total_sumsq - (total_sum * total_sum) / nullif(total_n, 0))
            end as r2_step
        from running
        where running_n >= 3 and (total_n - running_n) >= 3
    ),
    best_split as (
        select distinct on (datname, metric_name)
            datname, metric_name, split_date, r2_step
        from split_r2
        order by datname, metric_name, r2_step desc nulls last
    ),
    combined as (
        select
            ac.datname, ac.metric_name,
            coalesce(gs.sample_count, 0) as sample_count,
            gs.median_value, gs.r2_line, gs.tss,
            sc.median_slope,
            bs.split_date, bs.r2_step,
            coalesce(cf.composition_change, false) as composition_change
        from all_combos ac
        left join group_stats gs      on gs.datname = ac.datname and gs.metric_name = ac.metric_name
        left join slope_calc  sc      on sc.datname = ac.datname and sc.metric_name = ac.metric_name
        left join best_split  bs      on bs.datname = ac.datname and bs.metric_name = ac.metric_name
        left join composition_flag cf on cf.datname = ac.datname
    ),
    classified as (
        select
            datname, metric_name, sample_count, median_value, median_slope, split_date,
            composition_change,
            case
                when sample_count < v_min_weeks then 'insufficient_data'
                when coalesce(tss, 0) = 0 then 'stable'
                when coalesce(r2_step, 0) < v_min_r2 and coalesce(r2_line, 0) < v_min_r2 then 'stable'
                when composition_change then 'composition'
                when coalesce(r2_step, 0) >= coalesce(r2_line, 0) + v_step_r2_margin then 'step'
                else 'drift'
            end as classification
        from combined
    )
    insert into pgfr_analyze.consumption_trends (
        as_of_date, datname, metric_name, window_days, basket_version,
        sample_count, baseline_start, baseline_end,
        slope_pct_per_30d, classification, changepoint_date, composition_change
    )
    select
        v_as_of_date, datname, metric_name, v_window_days, v_basket_version,
        sample_count, v_as_of_date - v_window_days + 1, v_as_of_date,
        case
            when classification = 'insufficient_data' then null
            when median_value is null or median_value = 0 then null
            else median_slope * 30 / abs(median_value) * 100
        end,
        classification,
        case when classification = 'step' then split_date else null end,
        composition_change
    from classified
    on conflict (as_of_date, datname, metric_name, window_days)
    do update set
        basket_version     = excluded.basket_version,
        sample_count       = excluded.sample_count,
        baseline_start     = excluded.baseline_start,
        baseline_end       = excluded.baseline_end,
        slope_pct_per_30d  = excluded.slope_pct_per_30d,
        classification     = excluded.classification,
        changepoint_date   = excluded.changepoint_date,
        composition_change = excluded.composition_change,
        computed_at        = now();
exception when others then
    raise warning 'pgfr_analyze: _refresh_consumption_trends_weekly failed: %', sqlerrm;
end;
$$;

comment on function pgfr_analyze._refresh_consumption_trends_weekly() is
'Weekly-grain sibling of _refresh_consumption_trends(): recomputes and '
'upserts today''s consumption_trends row (window_days=84) for every '
'(datname, basket metric), on consumption_weekly_metric_series points '
'instead of daily ones. Same Theil-Sen slope + R2-based step/drift/stable '
'classification, and the same composition-drift guard (two fixed 6-week '
'halves instead of two fixed 14-day halves), deliberately duplicated rather '
'than unified with the daily engine (see file header). Gated by '
'consumption_trend_min_weeks (default 8); reuses consumption_trend_min_r2, '
'consumption_trend_step_r2_margin, and consumption_trend_shape_guard_pct '
'from the daily engine (grain-agnostic thresholds). Non-fatal on failure '
'(wrapped in EXCEPTION, emits WARNING). See Issue #92.';
