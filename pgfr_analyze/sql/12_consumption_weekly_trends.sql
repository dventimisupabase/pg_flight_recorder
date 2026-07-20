-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

--------------------------------------------------------------------------------
-- Consumption trend engine, 90-day window, phase B of 4 (Issue #92).
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
-- This phase deliberately does NOT include the composition-drift guard --
-- that's phase C, mirroring how #83 shipped Theil-Sen slope + step/drift/
-- stable classification (phase 2) before composition (phase 3). Every row
-- written here has composition_change = false: not "checked and clear," but
-- "not evaluated yet at this grain."
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
    v_as_of_date     date := current_date;
    v_window_days    constant integer := 84;
    v_basket_version constant integer := 1;
    v_min_weeks      integer;
    v_min_r2         numeric;
    v_step_r2_margin numeric;
begin
    v_min_weeks      := coalesce(pgfr_record._get_config('consumption_trend_min_weeks', '8')::integer, 8);
    v_min_r2         := coalesce(pgfr_record._get_config('consumption_trend_min_r2', '0.3')::numeric, 0.3);
    v_step_r2_margin := coalesce(pgfr_record._get_config('consumption_trend_step_r2_margin', '0.15')::numeric, 0.15);

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
            bs.split_date, bs.r2_step
        from all_combos ac
        left join group_stats gs on gs.datname = ac.datname and gs.metric_name = ac.metric_name
        left join slope_calc  sc on sc.datname = ac.datname and sc.metric_name = ac.metric_name
        left join best_split  bs on bs.datname = ac.datname and bs.metric_name = ac.metric_name
    ),
    classified as (
        select
            datname, metric_name, sample_count, median_value, median_slope, split_date,
            case
                when sample_count < v_min_weeks then 'insufficient_data'
                when coalesce(tss, 0) = 0 then 'stable'
                when coalesce(r2_step, 0) < v_min_r2 and coalesce(r2_line, 0) < v_min_r2 then 'stable'
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
        false  -- composition guard not evaluated at this grain yet (phase C)
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
'instead of daily ones. Same Theil-Sen slope + step/drift/stable '
'classification logic, deliberately duplicated rather than unified with the '
'daily engine (see file header). composition_change is always false here --'
'not evaluated at this grain yet, phase C''s job. Gated by '
'consumption_trend_min_weeks (default 8); reuses consumption_trend_min_r2 '
'and consumption_trend_step_r2_margin from the daily engine (grain-agnostic '
'thresholds). Non-fatal on failure (wrapped in EXCEPTION, emits WARNING). '
'See Issue #92.';
