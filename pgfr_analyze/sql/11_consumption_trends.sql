-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

--------------------------------------------------------------------------------
-- Consumption trend engine, phase 2 of 4 (Issue #83).
--
-- Phase 1 (pgfr_record.consumption_daily_flows, merged) reconstructs daily
-- ratios from the consumption ledger's daily rollups. This phase persists a
-- trend assessment for each of the issue's 8 basket metrics: a robust slope
-- (Theil-Sen), and a classification distinguishing a genuine level shift
-- ("step") from a gradual change ("drift") from noise ("stable").
--
-- 28-day window only, on raw daily points. The 90-day/weekly-aggregated
-- window (needed for real seasonality handling -- see the README) is a later
-- phase; extending to it should mean a sibling function, not a rewrite of
-- this one.
--
-- No new pg_cron job: pgfr_analyze has never had one (every function in it is
-- on-demand), and Theil-Sen over <=90 points is cheap enough that
-- _refresh_consumption_trends() just always recomputes fully rather than
-- tracking staleness. It's meant to be called from the eventual report entry
-- point (phase 4), and directly for now.
--
-- Step vs. drift is NOT a magnitude threshold. A clean level-shift and a
-- linear ramp over the same window can produce the *same* shift-magnitude-to-
-- MAD ratio (verified by hand before writing this), so no multiplier
-- distinguishes them on magnitude alone. Instead this compares model fit:
-- a straight line (regr_r2) vs. the best-fitting two-level step (the split
-- point minimizing within-group variance, found via running sums/sums-of-
-- squares -- no correlated subqueries). A step's step-model R2 beats its
-- line-fit R2 by a real margin; a ramp's line fit is already good, so a step
-- model doesn't buy anything. slope_pct_per_30d (Theil-Sen, normalized to the
-- window's own median) is always computed and stored for reporting
-- regardless of which way the R2 comparison classifies the shape.
--
-- No composition_change column yet -- that needs the workload-shape-guard
-- comparison, phase 3's job. Adding it there as a genuine additive column
-- when its logic exists, rather than pre-declaring it empty now.
--------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. consumption_metric_series — long-format unpivot of the 8 basket metrics
--    from consumption_daily_flows. Exists so the trend computation below is
--    written once, generically (GROUP BY metric_name), rather than once per
--    metric with per-column dynamic SQL. Internal to the trend engine (not a
--    general-purpose ratio view like consumption_daily_flows), hence living
--    in pgfr_analyze rather than pgfr_record.
-- ---------------------------------------------------------------------------
create or replace view pgfr_analyze.consumption_metric_series as
select rollup_date, datname, 'blocks_per_row_returned'::text as metric_name, blocks_per_row_returned as value
from pgfr_record.consumption_daily_flows
union all
select rollup_date, datname, 'wal_bytes_per_row_mutated', wal_bytes_per_row_mutated
from pgfr_record.consumption_daily_flows
union all
select rollup_date, datname, 'temp_bytes_per_xact', temp_bytes_per_xact
from pgfr_record.consumption_daily_flows
union all
select rollup_date, datname, 'fpi_fraction', fpi_fraction
from pgfr_record.consumption_daily_flows
union all
select rollup_date, datname, 'ckpt_requested_fraction', ckpt_requested_fraction
from pgfr_record.consumption_daily_flows
union all
select rollup_date, datname, 'rollback_fraction', rollback_fraction
from pgfr_record.consumption_daily_flows
union all
select rollup_date, datname, 'autovacuum_write_share', autovacuum_write_share
from pgfr_record.consumption_daily_flows
union all
select rollup_date, datname, 'cache_hit_fraction', cache_hit_fraction
from pgfr_record.consumption_daily_flows;

comment on view pgfr_analyze.consumption_metric_series is
'Long-format (rollup_date, datname, metric_name, value) unpivot of '
'pgfr_record.consumption_daily_flows'' 8 basket metrics (Issue #83). '
'Lets _refresh_consumption_trends() compute generically via GROUP BY '
'metric_name instead of per-metric dynamic SQL. NULL values (reset-excluded '
'day, or zero denominator) are filtered out downstream, per metric -- a '
'metric that''s always NULL (e.g. autovacuum_write_share on PG15) cannot '
'affect any other metric''s trend, since each metric''s point-set is built '
'and filtered independently.';

-- ---------------------------------------------------------------------------
-- 2. consumption_trends — the persisted trend table.
--    One row per (as_of_date, datname, metric_name, window_days), upserted on
--    every refresh: as_of_date accumulates a genuine history across different
--    calendar days, not just the latest snapshot. Tiny by construction (8
--    metrics x 1 window/day today), so -- same reasoning as
--    consumption_daily_rollups -- no partitioning, no retention: it's meant
--    to be kept indefinitely (it IS the long-term memory, per Issue #83).
-- ---------------------------------------------------------------------------
create table if not exists pgfr_analyze.consumption_trends (
    as_of_date          date        not null,
    datname             text        not null,
    metric_name         text        not null,
    window_days         integer     not null,
    basket_version      integer     not null,

    sample_count        integer     not null,
    baseline_start      date        not null,
    baseline_end        date        not null,

    slope_pct_per_30d   numeric,
    classification      text        not null
        check (classification in ('insufficient_data', 'stable', 'drift', 'step', 'composition')),
    changepoint_date    date,
    check ((classification = 'step') = (changepoint_date is not null)),
    composition_change  boolean     not null default false,

    computed_at         timestamptz not null default now(),

    primary key (as_of_date, datname, metric_name, window_days)
);

-- Additive upgrade path for installs from phase 2 (before composition_change
-- and the 'composition' classification value existed). SET LOCAL silences the
-- "does not exist, skipping" notice on fresh installs where these are already
-- correct from the CREATE TABLE above. CHECK constraints can't be altered in
-- place, so the classification constraint is dropped and recreated.
do $$
begin
    set local client_min_messages = warning;
    alter table pgfr_analyze.consumption_trends
        add column if not exists composition_change boolean not null default false;
    alter table pgfr_analyze.consumption_trends
        drop constraint if exists consumption_trends_classification_check;
    alter table pgfr_analyze.consumption_trends
        add constraint consumption_trends_classification_check
        check (classification in ('insufficient_data', 'stable', 'drift', 'step', 'composition'));
end $$;

comment on table pgfr_analyze.consumption_trends is
'Persisted trend assessments for the consumption ledger''s metric basket '
'(Issue #83): one row per (as_of_date, datname, metric_name, window_days), '
'upserted per refresh so history accumulates across days rather than being '
'overwritten. window_days is always 28 in this phase; a 90-day/weekly-'
'aggregated window is a later addition, same table. Not partitioned, no '
'retention: tiny by construction, meant to be kept indefinitely.';

comment on column pgfr_analyze.consumption_trends.sample_count is
'Count of days with a non-NULL value for this metric in the window. Recorded '
'even when 0 (a metric that''s always NULL, e.g. autovacuum_write_share on '
'PG15, still gets an explicit insufficient_data row) -- Issue #83 requires '
'insufficient-data states to be explicit, never silently omitted.';

comment on column pgfr_analyze.consumption_trends.slope_pct_per_30d is
'Theil-Sen slope (median of all pairwise slopes -- robust to outliers), '
'normalized to %/30d relative to the window''s own median value so metrics '
'of different scale are comparable. NULL when classification is '
'insufficient_data. Always computed regardless of step/drift/stable '
'classification -- the classification is about shape, this is magnitude.';

comment on column pgfr_analyze.consumption_trends.classification is
'stable: neither a line nor a step fits meaningfully better than noise. '
'drift: a material change, but gradual -- a line fits the window at least as '
'well as any single step does. step: a genuine level shift -- the '
'best-fitting two-level step explains the window''s variance meaningfully '
'better than the best-fitting line (see changepoint_date). composition: a '
'movement was detected (would otherwise be step or drift) but the window''s '
'workload-shape indicators also moved beyond threshold between the window''s '
'halves (see composition_change) -- no fitness inference is safe, so no '
'changepoint_date either. A metric that never moved (stable) stays stable '
'even if the workload shape also changed that window: there''s nothing to '
'misattribute in the first place. Not a magnitude threshold for step vs '
'drift: distinguishing them requires comparing model fit, not shift size -- '
'a clean step and a linear ramp over the same window can produce the same '
'shift-magnitude-to-variability ratio.';

comment on column pgfr_analyze.consumption_trends.composition_change is
'True when this window''s workload-shape indicators (read_write_tuple_ratio, '
'xact_per_s, rows_returned_per_xact, rows_mutated_per_xact, db_size_bytes) '
'moved beyond consumption_trend_shape_guard_pct between the window''s two '
'fixed halves. One value per (datname, as_of_date, window_days), applied to '
'every metric''s row for that window -- workload shape is a property of the '
'window, not of any one metric. Issue #83''s composition-drift confound: a '
'ratio can move because the database got less fit, or because the workload '
'mix changed; this is the honesty flag preventing the latter from being '
'reported as the former.';

-- ---------------------------------------------------------------------------
-- 3. _pct_shift_exceeds() — generic, testable percent-shift check used by the
--    workload-shape guard below. NULL-safe (either input missing means no
--    signal, not an error) and treats a 0-to-nonzero shift as automatically
--    exceeding: a metric going from "never happens" to "happens" (or back)
--    has an undefined percentage change, but is still a real shape shift.
-- ---------------------------------------------------------------------------
create or replace function pgfr_analyze._pct_shift_exceeds(
    p_before        numeric,
    p_after         numeric,
    p_threshold_pct numeric
)
returns boolean
language sql
immutable
as $$
    select case
        when p_before is null or p_after is null then false
        when p_before = 0 and p_after = 0 then false
        when p_before = 0 then true
        else abs(p_after - p_before) / abs(p_before) * 100 > p_threshold_pct
    end
$$;

comment on function pgfr_analyze._pct_shift_exceeds(numeric, numeric, numeric) is
'Generic percent-shift check: true if p_after differs from p_before by more '
'than p_threshold_pct percent. NULL-safe (false if either side is unknown); '
'a 0-to-nonzero shift always exceeds (percentage change is undefined, but '
'"never happens" becoming "happens" is a real shift). Used by the workload-'
'shape guard in _refresh_consumption_trends(). See Issue #83.';

-- ---------------------------------------------------------------------------
-- 4. _refresh_consumption_trends() — always recomputes and upserts today's
--    row for every (datname, basket metric) combination, 28-day window.
-- ---------------------------------------------------------------------------
create or replace function pgfr_analyze._refresh_consumption_trends()
returns void
language plpgsql as $$
declare
    v_as_of_date      date := current_date;
    v_window_days     constant integer := 28;
    v_basket_version  constant integer := 1;
    v_min_days        integer;
    v_min_r2          numeric;
    v_step_r2_margin  numeric;
    v_shape_guard_pct numeric;
begin
    v_min_days        := coalesce(pgfr_record._get_config('consumption_trend_min_days', '14')::integer, 14);
    v_min_r2          := coalesce(pgfr_record._get_config('consumption_trend_min_r2', '0.3')::numeric, 0.3);
    v_step_r2_margin  := coalesce(pgfr_record._get_config('consumption_trend_step_r2_margin', '0.15')::numeric, 0.15);
    v_shape_guard_pct := coalesce(pgfr_record._get_config('consumption_trend_shape_guard_pct', '25')::numeric, 25);

    with window_points as (
        select
            s.datname, s.metric_name, s.rollup_date, s.value,
            (s.rollup_date - date '1970-01-01')::numeric as day_offset
        from pgfr_analyze.consumption_metric_series s
        where s.rollup_date > v_as_of_date - v_window_days
          and s.rollup_date <= v_as_of_date
          and s.value is not null
    ),
    -- One row per (datname, basket metric) -- including combinations with
    -- zero valid points this window -- so "always NULL this window" is an
    -- explicit insufficient_data row, never a silently missing one.
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
    -- Workload-shape guard (Issue #83's composition-drift confound): compare
    -- each shape indicator's mean between the window's two FIXED halves --
    -- not a searched split like the step/drift check below. The issue's own
    -- wording is "the trend window's halves," a 50/50 split, not "the best
    -- split we can find." One flag per datname, applied to every metric's row
    -- for that window: workload shape is a property of the window, not of
    -- any one metric.
    shape_halves as (
        select
            f.datname,
            count(*) as sample_count,
            avg(f.read_write_tuple_ratio) filter (where f.rollup_date <= v_as_of_date - v_window_days / 2) as rwtr_before,
            avg(f.read_write_tuple_ratio) filter (where f.rollup_date >  v_as_of_date - v_window_days / 2) as rwtr_after,
            avg(f.xact_per_s)             filter (where f.rollup_date <= v_as_of_date - v_window_days / 2) as xps_before,
            avg(f.xact_per_s)             filter (where f.rollup_date >  v_as_of_date - v_window_days / 2) as xps_after,
            avg(f.rows_returned_per_xact) filter (where f.rollup_date <= v_as_of_date - v_window_days / 2) as rrpx_before,
            avg(f.rows_returned_per_xact) filter (where f.rollup_date >  v_as_of_date - v_window_days / 2) as rrpx_after,
            avg(f.rows_mutated_per_xact)  filter (where f.rollup_date <= v_as_of_date - v_window_days / 2) as rmpx_before,
            avg(f.rows_mutated_per_xact)  filter (where f.rollup_date >  v_as_of_date - v_window_days / 2) as rmpx_after,
            avg(f.db_size_bytes)          filter (where f.rollup_date <= v_as_of_date - v_window_days / 2) as size_before,
            avg(f.db_size_bytes)          filter (where f.rollup_date >  v_as_of_date - v_window_days / 2) as size_after
        from pgfr_record.consumption_daily_flows f
        where f.rollup_date > v_as_of_date - v_window_days
          and f.rollup_date <= v_as_of_date
        group by f.datname
    ),
    composition_flag as (
        select
            datname,
            (
                sample_count >= v_min_days
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
            -- Verified empirically: Postgres's regr_r2 returns 1.0 (a
            -- "perfect fit"), not NULL/NaN, when the Y series has zero
            -- variance -- a flat line trivially explains a constant. That
            -- convention breaks the step-vs-line R2 comparison below for a
            -- genuinely constant metric, so zero-variance is handled as its
            -- own explicit early classification (see tss / "stable" check)
            -- rather than relying on r2_line to signal "nothing to detect."
            -- nullif(...,'nan') kept as defensive belt-and-suspenders for
            -- any other degenerate input regr_r2 might legitimately NaN on.
            nullif(regr_r2(value, day_offset), 'nan'::double precision) as r2_line,
            (sum(value * value) - power(sum(value), 2) / nullif(count(*), 0)) as tss
        from window_points
        group by datname, metric_name
    ),
    -- Theil-Sen: median of every pairwise slope. O(n^2) pairs on <=28 points
    -- is trivial (Issue #83's own framing).
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
    -- Best-fitting two-level step: running sums and sums-of-squares give
    -- before/after group variance at every candidate split without a
    -- correlated subquery per split.
    running as (
        select
            datname, metric_name, rollup_date,
            count(*)         over w as running_n,
            sum(value)       over w as running_sum,
            sum(value*value) over w as running_sumsq,
            count(*)         over (partition by datname, metric_name) as total_n,
            sum(value)       over (partition by datname, metric_name) as total_sum,
            sum(value*value) over (partition by datname, metric_name) as total_sumsq
        from window_points
        window w as (partition by datname, metric_name order by rollup_date)
    ),
    split_r2 as (
        select
            datname, metric_name, rollup_date as split_date,
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
                when sample_count < v_min_days then 'insufficient_data'
                -- Zero variance: nothing to detect. Handled explicitly rather
                -- than relying on r2_line, which is 1.0 (not NULL/low) for a
                -- constant series -- see the comment on group_stats.r2_line.
                when coalesce(tss, 0) = 0 then 'stable'
                when coalesce(r2_step, 0) < v_min_r2 and coalesce(r2_line, 0) < v_min_r2 then 'stable'
                -- Composition only overrides a *detected* movement (a metric
                -- that's already stable has nothing to misattribute), so this
                -- check sits after both stable checks and before step/drift.
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
    raise warning 'pgfr_analyze: _refresh_consumption_trends failed: %', sqlerrm;
end;
$$;

comment on function pgfr_analyze._refresh_consumption_trends() is
'Recomputes and upserts today''s consumption_trends row for every (datname, '
'basket metric), 28-day window on raw daily points. Also evaluates the '
'workload-shape guard (composition_change) once per datname from the '
'window''s two fixed halves, applied to every metric''s row. Always fully '
'recomputes (no staleness tracking -- cheap enough not to need it). '
'Thresholds (consumption_trend_min_days default 14, consumption_trend_min_r2 '
'default 0.3, consumption_trend_step_r2_margin default 0.15, '
'consumption_trend_shape_guard_pct default 25) are pgfr_record.config keys '
'read via _get_config(), never written by pgfr_analyze. Non-fatal on failure '
'(wrapped in EXCEPTION, emits WARNING). See Issue #83.';

--------------------------------------------------------------------------------
-- Phase 4 of 4: the report renderer.
--
-- Vocabulary is part of the spec (Issue #83): "specific consumption" and
-- "amplification factor" are terms of art and appear as section headers
-- verbatim. Every classification's phrasing stays purely factual -- state the
-- figure, the trend, the classification, stop -- rather than using any of the
-- issue's explicitly-permitted "fitness-consistent" language for unflagged
-- drift/step: given the strict adjective ban elsewhere in the same spec, the
-- safer reading is no interpretive language anywhere, not just on flagged
-- windows.
--------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 5. _sparkline() — renders a numeric[] as a Unicode block-bar string.
--    Standalone and independently testable, same reasoning as
--    _reset_guarded_delta()/_pct_shift_exceeds(). NULLs render as an explicit
--    gap marker rather than being silently skipped (dropping a NULL would
--    shift every later bar left, making a gap invisible instead of honest).
--    A constant series (zero range) renders as a flat mid-level bar rather
--    than dividing by zero.
-- ---------------------------------------------------------------------------
create or replace function pgfr_analyze._sparkline(p_values numeric[])
returns text
language plpgsql
immutable
as $$
declare
    v_chars  constant text[] := array['▁','▂','▃','▄','▅','▆','▇','█'];
    v_min    numeric;
    v_max    numeric;
    v_range  numeric;
    v_result text := '';
    v_val    numeric;
    v_level  integer;
begin
    select min(v), max(v) into v_min, v_max from unnest(p_values) as v where v is not null;
    if v_min is null then
        return '';
    end if;
    v_range := v_max - v_min;

    foreach v_val in array p_values loop
        if v_val is null then
            v_result := v_result || '·';
        elsif v_range = 0 then
            v_result := v_result || v_chars[4];
        else
            -- Multiply before dividing: numeric division of a repeating
            -- decimal (e.g. 1/7) rounds, and re-multiplying that rounded
            -- value by 7 does not reliably cancel back out (observed:
            -- floor(1/7*7) = 0, not 1). (v-min)*7/range divides only once,
            -- at the end, avoiding the compounded rounding error.
            v_level  := greatest(0, least(7, floor((v_val - v_min) * 7 / v_range)::integer));
            v_result := v_result || v_chars[v_level + 1];
        end if;
    end loop;

    return v_result;
end;
$$;

comment on function pgfr_analyze._sparkline(numeric[]) is
'Renders a numeric[] as a Unicode block-bar sparkline (8 levels, relative to '
'the array''s own min/max). NULL entries render as "·" (an explicit gap, not '
'a silently-skipped one -- dropping it would shift later bars left). A '
'constant array (zero range) renders as a flat mid-level bar. Used by '
'consumption_trend_report(). See Issue #83.';

-- ---------------------------------------------------------------------------
-- 6. _render_consumption_trend_window() — one (metric, window) block:
--    a small window label, classification line (purely factual phrasing, no
--    adjectives), changepoint or composition note where applicable,
--    sparkline. Factored out so the report doesn't repeat the same rendering
--    logic once per metric per window. Renamed from
--    _render_consumption_trend_metric() when Issue #92 added the 84-day
--    window: it used to print the "### metric name" heading itself, but now
--    that consumption_trend_report() shows two windows per metric, the
--    heading is the caller's job, printed once, with this function called
--    twice underneath it. p_grain ('daily' or 'weekly') picks the sparkline
--    source and the insufficient-data unit ("days" vs "weeks") -- the only
--    two places rendering actually depends on grain; everything else here is
--    identical regardless of which engine populated the row.
-- ---------------------------------------------------------------------------
drop function if exists pgfr_analyze._render_consumption_trend_metric(text, text, integer, integer);

create or replace function pgfr_analyze._render_consumption_trend_window(
    p_datname      text,
    p_metric_name  text,
    p_window_days  integer,
    p_min_periods  integer,
    p_grain        text  -- 'daily' (consumption_metric_series/rollup_date) or 'weekly' (consumption_weekly_metric_series/week_end_date)
)
returns text
language plpgsql as $$
declare
    v_trend  record;
    v_values numeric[];
    v_result text;
begin
    select * into v_trend
    from pgfr_analyze.consumption_trends
    where datname = p_datname and metric_name = p_metric_name and window_days = p_window_days
    order by as_of_date desc
    limit 1;

    v_result := '**' || p_window_days || '-day window**' || E'\n';

    if not found then
        return v_result || 'No data collected yet.' || E'\n\n';
    end if;

    if v_trend.classification = 'insufficient_data' then
        return v_result || 'Insufficient data: ' || p_min_periods || ' '
            || (case when p_grain = 'weekly' then 'weeks' else 'days' end)
            || ' required, ' || v_trend.sample_count || ' collected.' || E'\n\n';
    end if;

    v_result := v_result || 'Classification: ' || v_trend.classification;
    if v_trend.slope_pct_per_30d is not null then
        v_result := v_result || ' (' || round(v_trend.slope_pct_per_30d, 1) || '%/30d)';
    end if;
    v_result := v_result || E'\n';

    -- Every classification gets an explicit, purely factual sentence -- state
    -- the figure, the trend, the classification, stop. No adjectives, even
    -- for the cases Issue #83 would permit "fitness-consistent" language on.
    if v_trend.classification = 'stable' then
        v_result := v_result || 'No material change detected.' || E'\n';
    elsif v_trend.classification = 'drift' then
        v_result := v_result || 'Gradual change detected.' || E'\n';
    elsif v_trend.classification = 'step' then
        v_result := v_result || 'Level shift detected on ' || v_trend.changepoint_date || '.' || E'\n';
    elsif v_trend.classification = 'composition' then
        v_result := v_result || 'A change was detected, but the workload mix also shifted '
            || 'during this window -- no attribution made.' || E'\n';
    end if;

    if p_grain = 'weekly' then
        select array_agg(s.value order by s.week_end_date) into v_values
        from pgfr_analyze.consumption_weekly_metric_series s
        where s.datname = p_datname and s.metric_name = p_metric_name
          and s.week_end_date >= v_trend.baseline_start and s.week_end_date <= v_trend.baseline_end;
    else
        select array_agg(s.value order by s.rollup_date) into v_values
        from pgfr_analyze.consumption_metric_series s
        where s.datname = p_datname and s.metric_name = p_metric_name
          and s.rollup_date >= v_trend.baseline_start and s.rollup_date <= v_trend.baseline_end;
    end if;

    v_result := v_result || '`' || pgfr_analyze._sparkline(v_values) || '`' || E'\n\n';

    return v_result;
end;
$$;

comment on function pgfr_analyze._render_consumption_trend_window(text, text, integer, integer, text) is
'Renders one (metric, window) block for consumption_trend_report(): window '
'label, factual classification line (no adjectives), changepoint/composition '
'note where applicable, sparkline. p_grain selects the sparkline source '
'(consumption_metric_series for daily, consumption_weekly_metric_series for '
'weekly) and the insufficient-data unit. The "### metric name" heading is '
'the caller''s job -- this function is called once per window underneath it. '
'See Issue #83, #92.';

-- ---------------------------------------------------------------------------
-- 7. consumption_trend_report() — the user-facing entry point. Calls both
--    _refresh_consumption_trends() and _refresh_consumption_trends_weekly()
--    first (refresh-on-read, matching every other pgfr_analyze function --
--    this extension has never had a cron job and Theil-Sen over <=90 points
--    is cheap enough not to need one), then renders a markdown report with
--    both the 28-day/daily and 84-day/weekly windows shown per metric
--    (Issue #92 phase D, the last phase of that issue). Each metric gets a
--    single "### metric name" heading followed by its two window blocks
--    (daily, then weekly) from _render_consumption_trend_window() -- see
--    that function's header for why the heading lives here instead.
-- ---------------------------------------------------------------------------
create or replace function pgfr_analyze.consumption_trend_report(
    p_datname text default current_database()
)
returns text
language plpgsql as $$
declare
    v_window_days_daily  constant integer := 28;
    v_window_days_weekly constant integer := 84;
    v_min_days       integer;
    v_min_weeks      integer;
    v_result         text := '';
    v_baseline_daily  record;
    v_baseline_weekly record;
    v_found_daily     boolean;
    v_found_weekly    boolean;
begin
    perform pgfr_analyze._refresh_consumption_trends();
    perform pgfr_analyze._refresh_consumption_trends_weekly();

    v_min_days  := coalesce(pgfr_record._get_config('consumption_trend_min_days', '14')::integer, 14);
    v_min_weeks := coalesce(pgfr_record._get_config('consumption_trend_min_weeks', '8')::integer, 8);

    v_result := v_result || '# Consumption Trend Report' || E'\n\n';
    v_result := v_result || '**Database:** ' || p_datname || E'\n';
    v_result := v_result || '**Generated:** ' || to_char(now(), 'YYYY-MM-DD HH24:MI:SS TZ') || E'\n\n';

    select as_of_date, baseline_start, baseline_end into v_baseline_daily
    from pgfr_analyze.consumption_trends
    where datname = p_datname and window_days = v_window_days_daily
    order by as_of_date desc
    limit 1;
    v_found_daily := found;

    select as_of_date, baseline_start, baseline_end into v_baseline_weekly
    from pgfr_analyze.consumption_trends
    where datname = p_datname and window_days = v_window_days_weekly
    order by as_of_date desc
    limit 1;
    v_found_weekly := found;

    if not v_found_daily and not v_found_weekly then
        v_result := v_result || 'No consumption trend data collected yet for this database.' || E'\n';
        return v_result;
    end if;

    if v_found_daily then
        v_result := v_result || '**28-day baseline:** ' || v_baseline_daily.baseline_start || ' -> '
            || v_baseline_daily.baseline_end || E'\n';
    end if;
    if v_found_weekly then
        v_result := v_result || '**84-day baseline:** ' || v_baseline_weekly.baseline_start || ' -> '
            || v_baseline_weekly.baseline_end || E'\n';
    end if;
    v_result := v_result || E'\n';

    v_result := v_result || '## Specific consumption' || E'\n\n';
    v_result := v_result || '### blocks_per_row_returned' || E'\n\n';
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'blocks_per_row_returned', v_window_days_daily, v_min_days, 'daily');
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'blocks_per_row_returned', v_window_days_weekly, v_min_weeks, 'weekly');
    v_result := v_result || '### wal_bytes_per_row_mutated' || E'\n\n';
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'wal_bytes_per_row_mutated', v_window_days_daily, v_min_days, 'daily');
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'wal_bytes_per_row_mutated', v_window_days_weekly, v_min_weeks, 'weekly');
    v_result := v_result || '### temp_bytes_per_xact' || E'\n\n';
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'temp_bytes_per_xact', v_window_days_daily, v_min_days, 'daily');
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'temp_bytes_per_xact', v_window_days_weekly, v_min_weeks, 'weekly');

    v_result := v_result || '## Amplification factors' || E'\n\n';
    v_result := v_result || '### fpi_fraction' || E'\n\n';
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'fpi_fraction', v_window_days_daily, v_min_days, 'daily');
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'fpi_fraction', v_window_days_weekly, v_min_weeks, 'weekly');
    v_result := v_result || '### ckpt_requested_fraction' || E'\n\n';
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'ckpt_requested_fraction', v_window_days_daily, v_min_days, 'daily');
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'ckpt_requested_fraction', v_window_days_weekly, v_min_weeks, 'weekly');
    v_result := v_result || '### rollback_fraction' || E'\n\n';
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'rollback_fraction', v_window_days_daily, v_min_days, 'daily');
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'rollback_fraction', v_window_days_weekly, v_min_weeks, 'weekly');
    v_result := v_result || '### autovacuum_write_share' || E'\n\n';
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'autovacuum_write_share', v_window_days_daily, v_min_days, 'daily');
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'autovacuum_write_share', v_window_days_weekly, v_min_weeks, 'weekly');

    v_result := v_result || '## Substrate' || E'\n\n';
    v_result := v_result || '### cache_hit_fraction' || E'\n\n';
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'cache_hit_fraction', v_window_days_daily, v_min_days, 'daily');
    v_result := v_result || pgfr_analyze._render_consumption_trend_window(p_datname, 'cache_hit_fraction', v_window_days_weekly, v_min_weeks, 'weekly');

    return v_result;
end;
$$;

comment on function pgfr_analyze.consumption_trend_report(text) is
'Markdown consumption trend report for p_datname (default current_database()). '
'Refreshes consumption_trends for both windows first (refresh-on-read, no '
'cron dependency), then renders Specific consumption / Amplification factors '
'/ Substrate sections using this schema''s Issue #83 vocabulary verbatim. '
'Each metric gets one heading followed by its 28-day/daily and 84-day/weekly '
'window blocks, each with a factual classification line (no adjectives -- '
'state the figure, the trend, the classification, stop) and a sparkline. '
'See Issue #83, #92.';
