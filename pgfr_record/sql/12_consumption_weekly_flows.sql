-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

--------------------------------------------------------------------------------
-- Consumption trend engine, 90-day window, phase A of 4 (Issue #92).
--
-- consumption_weekly_flows is the weekly-grain sibling of
-- consumption_daily_flows: the same Σnum/Σden reconstruction (re-sum the
-- underlying components, then derive each ratio -- never average
-- finer-grained ratios), one tier up. No new physical table: unlike the
-- daily rollup, this doesn't need one -- consumption_daily_rollups never
-- expires (no partition/retention), so re-aggregating it into weekly buckets
-- on every read is cheap and always current, exactly like
-- consumption_daily_flows already does one tier down.
--
-- Bucketing is rolling 7-day windows counting backward from current_date,
-- not ISO calendar weeks: the most recent ISO week is usually partial (only
-- a few days collected so far), and a partial week's sum next to full weeks'
-- sums would reintroduce the exact naive distortion aggregating exists to
-- avoid. Rolling buckets are always complete by construction and are
-- consistent with how the 28-day window already works (rolling relative to
-- as_of_date, not calendar-aligned). week_index 0 is the most recent 7 days
-- (today back to 6 days ago); week_index N is N weeks further back.
-- week_end_date is the bucket's anchor (most recent day in it), matching how
-- consumption_daily_rollups.rollup_date already represents an interval's end
-- timestamp, not its start.
--------------------------------------------------------------------------------

create or replace view pgfr_record.consumption_weekly_flows as
with weekly_sums as (
    select
        datname,
        (current_date - rollup_date) / 7                         as week_index,
        current_date - ((current_date - rollup_date) / 7) * 7    as week_end_date,
        sum(total_seconds)             as total_seconds,
        sum(valid_tick_count)          as valid_tick_count,
        sum(blks_hit_sum)              as blks_hit_sum,
        sum(blks_read_sum)             as blks_read_sum,
        sum(tup_returned_sum)          as tup_returned_sum,
        sum(tup_mutated_sum)           as tup_mutated_sum,
        sum(xact_commit_sum)           as xact_commit_sum,
        sum(xact_rollback_sum)         as xact_rollback_sum,
        sum(temp_bytes_sum)            as temp_bytes_sum,
        sum(recorder_blks_hit_sum)     as recorder_blks_hit_sum,
        sum(recorder_blks_read_sum)    as recorder_blks_read_sum,
        sum(wal_bytes_sum)             as wal_bytes_sum,
        sum(wal_fpi_sum)               as wal_fpi_sum,
        sum(wal_bytes_advisory_sum)    as wal_bytes_advisory_sum,
        sum(ckpt_num_timed_sum)        as ckpt_num_timed_sum,
        sum(ckpt_num_requested_sum)    as ckpt_num_requested_sum,
        sum(io_writes_autovacuum_sum)  as io_writes_autovacuum_sum,
        sum(io_writes_total_sum)       as io_writes_total_sum,
        -- Gauge, not a flow: the week's last observed value, not a sum
        -- (same reasoning as consumption_daily_rollups.db_size_bytes).
        (array_agg(db_size_bytes order by rollup_date desc))[1] as db_size_bytes
    from pgfr_record.consumption_daily_rollups
    group by datname, (current_date - rollup_date) / 7
)
select
    week_end_date, datname, week_index, total_seconds, valid_tick_count,

    -- Specific consumption (headline)
    (blks_hit_sum + blks_read_sum)::numeric / nullif(tup_returned_sum, 0) as blocks_per_row_returned,
    wal_bytes_sum / nullif(tup_mutated_sum, 0) as wal_bytes_per_row_mutated,
    temp_bytes_sum::numeric / nullif(xact_commit_sum, 0) as temp_bytes_per_xact,

    -- Amplification / mechanically unambiguous
    (wal_fpi_sum * current_setting('block_size')::numeric) / nullif(wal_bytes_advisory_sum, 0) as fpi_fraction,
    ckpt_num_requested_sum::numeric / nullif(ckpt_num_timed_sum + ckpt_num_requested_sum, 0) as ckpt_requested_fraction,
    xact_rollback_sum::numeric / nullif(xact_commit_sum + xact_rollback_sum, 0) as rollback_fraction,
    io_writes_autovacuum_sum::numeric / nullif(io_writes_total_sum, 0) as autovacuum_write_share,

    -- Substrate (tracked, never called consumption)
    blks_hit_sum::numeric / nullif(blks_hit_sum + blks_read_sum, 0) as cache_hit_fraction,

    -- Workload-shape indicators (guards, not metrics -- see the composition-
    -- drift confound in Issue #83)
    tup_returned_sum::numeric / nullif(tup_mutated_sum, 0) as read_write_tuple_ratio,
    (xact_commit_sum + xact_rollback_sum)::numeric / nullif(total_seconds, 0) as xact_per_s,
    tup_returned_sum::numeric / nullif(xact_commit_sum + xact_rollback_sum, 0) as rows_returned_per_xact,
    tup_mutated_sum::numeric / nullif(xact_commit_sum + xact_rollback_sum, 0) as rows_mutated_per_xact,
    db_size_bytes,

    -- Self-accounting (footnote-grade; see consumption_flows.recorder_overhead_fraction)
    (recorder_blks_hit_sum + recorder_blks_read_sum)::numeric / nullif(blks_hit_sum + blks_read_sum, 0) as recorder_overhead_fraction
from weekly_sums;

comment on view pgfr_record.consumption_weekly_flows is
'Weekly-grain ratios reconstructed from consumption_daily_rollups, re-summed '
'into rolling 7-day buckets (week_index 0 = today back to 6 days ago, '
'counting backward -- not ISO calendar weeks, which would leave the most '
'recent bucket partial) and then derived the same way '
'consumption_daily_flows derives daily ratios -- never averaged from daily '
'ratios. No physical weekly rollup table: consumption_daily_rollups never '
'expires, so re-aggregating it fresh on every read is cheap and always '
'current. Unbounded history like consumption_daily_flows; callers (the '
'weekly trend engine, Issue #92) filter to whatever window they need. See '
'Issue #92.';

comment on column pgfr_record.consumption_weekly_flows.week_end_date is
'The bucket''s anchor date (the most recent day in its rolling 7-day span), '
'matching how consumption_daily_rollups.rollup_date already represents an '
'interval''s end, not its start. Stable per bucket regardless of which '
'day''s row happens to compute it, since it''s derived from week_index, not '
'from any individual row''s rollup_date.';

comment on column pgfr_record.consumption_weekly_flows.week_index is
'0 = the most recent complete rolling week (today back to 6 days ago), '
'counting backward through all available history. Exposed alongside '
'week_end_date mainly for debugging/testing; callers should filter on '
'week_end_date, the same way daily callers filter on rollup_date.';
