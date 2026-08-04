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
'[dimension] [date] The bucket''s anchor date (the most recent day in its '
'rolling 7-day span), matching how consumption_daily_rollups.rollup_date '
'already represents an interval''s end, not its start. Stable per bucket '
'regardless of which day''s row happens to compute it, since it''s derived '
'from week_index, not from any individual row''s rollup_date.';

comment on column pgfr_record.consumption_weekly_flows.datname is
'[dimension] [text] Database the per-database lanes are scoped to, carried '
'through from consumption_daily_rollups (always current_database(); the WAL, '
'io, and checkpointer lanes are cluster-wide).';

comment on column pgfr_record.consumption_weekly_flows.week_index is
'[dimension] [count] 0 = the most recent complete rolling week (today back to '
'6 days ago), counting backward through all available history. Exposed '
'alongside week_end_date mainly for debugging/testing; callers should filter '
'on week_end_date, the same way daily callers filter on rollup_date.';

comment on column pgfr_record.consumption_weekly_flows.total_seconds is
'[derived] [seconds] Elapsed wall time covered by the bucket''s valid ticks: '
'sum of consumption_daily_rollups.total_seconds across its 7 days. The '
'denominator for this view''s per-second rates, not an assumed 604800; a week '
'containing recorder downtime has proportionally fewer seconds.';

comment on column pgfr_record.consumption_weekly_flows.valid_tick_count is
'[derived] [count] Number of delta intervals that contributed to the '
'bucket''s sums (sum of consumption_daily_rollups.valid_tick_count over its 7 '
'days). Counts intervals present, not per-metric validity; low values flag '
'partial coverage.';

comment on column pgfr_record.consumption_weekly_flows.blocks_per_row_returned is
'[derived] [blocks/row] Buffer-pool block demand per row returned over the '
'week: (blks_hit_sum + blks_read_sum) over tup_returned_sum, each re-summed '
'across the bucket''s 7 days before dividing (never an average of daily '
'ratios). NULL when the denominator is zero; reset-excluded (NULL) days drop '
'out of the weekly sums rather than nulling the bucket.';

comment on column pgfr_record.consumption_weekly_flows.wal_bytes_per_row_mutated is
'[derived] [bytes/row] WAL bytes per row mutated over the week: wal_bytes_sum '
'(LSN odometer) over tup_mutated_sum (rows inserted + updated + deleted), '
're-summed across the bucket before dividing. NULL when the denominator is '
'zero; reset-excluded days drop out of the weekly sums.';

comment on column pgfr_record.consumption_weekly_flows.temp_bytes_per_xact is
'[derived] [bytes/xact] Temp-file bytes spilled per committed transaction '
'over the week: temp_bytes_sum over xact_commit_sum (commits only, rollbacks '
'excluded), re-summed across the bucket before dividing. NULL when the '
'denominator is zero; reset-excluded days drop out of the weekly sums.';

comment on column pgfr_record.consumption_weekly_flows.fpi_fraction is
'[derived] [fraction] Approximate share of the week''s WAL volume consumed by '
'full-page images, 0 to 1: wal_fpi_sum times block_size over '
'wal_bytes_advisory_sum (the advisory pg_stat_wal byte count), re-summed '
'across the bucket. NULL when the denominator is zero; reset-excluded days '
'drop out of the weekly sums.';

comment on column pgfr_record.consumption_weekly_flows.ckpt_requested_fraction is
'[derived] [fraction] Share of the week''s checkpoints that were requested '
'(forced) rather than scheduled, 0 to 1: ckpt_num_requested_sum over '
'(ckpt_num_timed_sum + ckpt_num_requested_sum), re-summed across the bucket. '
'NULL when no checkpoints occurred; reset-excluded days drop out of the '
'weekly sums.';

comment on column pgfr_record.consumption_weekly_flows.rollback_fraction is
'[derived] [fraction] Share of the week''s transactions that rolled back, 0 '
'to 1: xact_rollback_sum over (xact_commit_sum + xact_rollback_sum), '
're-summed across the bucket. NULL when the denominator is zero; '
'reset-excluded days drop out of the weekly sums.';

comment on column pgfr_record.consumption_weekly_flows.autovacuum_write_share is
'[derived] [fraction] Share of the week''s OS block write requests issued by '
'autovacuum workers, 0 to 1: io_writes_autovacuum_sum over '
'io_writes_total_sum (pg_stat_io, PG16+), re-summed across the bucket. NULL '
'on PG15 or when the denominator is zero.';

comment on column pgfr_record.consumption_weekly_flows.cache_hit_fraction is
'[derived] [fraction] Share of the week''s buffer-pool block demand satisfied '
'from shared buffers, 0 to 1: blks_hit_sum over (blks_hit_sum + '
'blks_read_sum), re-summed across the bucket. Substrate indicator, never '
'called consumption. NULL when the denominator is zero.';

comment on column pgfr_record.consumption_weekly_flows.read_write_tuple_ratio is
'[derived] [ratio] Workload-shape guard, not a consumption metric: '
'tup_returned_sum over tup_mutated_sum for the week, re-summed across the '
'bucket. Unbounded (a read-heavy week is far above 1). NULL when no rows '
'were mutated.';

comment on column pgfr_record.consumption_weekly_flows.xact_per_s is
'[counter-delta] [count/s] [interval-mean] Transactions per second, commits '
'plus rollbacks: (xact_commit_sum + xact_rollback_sum) over total_seconds, '
'the bucket''s covered seconds. Mean rate over the week, never instantaneous; '
'carries no sub-week burst information.';

comment on column pgfr_record.consumption_weekly_flows.rows_returned_per_xact is
'[derived] [rows/xact] Workload-shape guard: rows returned per transaction '
'for the week, tup_returned_sum over (xact_commit_sum + xact_rollback_sum), '
're-summed across the bucket. NULL when the denominator is zero.';

comment on column pgfr_record.consumption_weekly_flows.rows_mutated_per_xact is
'[derived] [rows/xact] Workload-shape guard: rows mutated per transaction '
'for the week, tup_mutated_sum over (xact_commit_sum + xact_rollback_sum), '
're-summed across the bucket. NULL when the denominator is zero.';

comment on column pgfr_record.consumption_weekly_flows.db_size_bytes is
'[gauge] [bytes] The bucket''s most recent observed database size: the last '
'day''s consumption_daily_rollups.db_size_bytes (itself the day''s last '
'observed pg_database_size()), a level carried through rather than summed. '
'Exact at that reading, undefined between readings.';

comment on column pgfr_record.consumption_weekly_flows.recorder_overhead_fraction is
'[derived] [fraction] The recorder''s own share of the week''s total '
'buffer-pool block demand, 0 to 1: (recorder_blks_hit_sum + '
'recorder_blks_read_sum) over (blks_hit_sum + blks_read_sum), re-summed '
'across the bucket. Footnote-grade self-accounting. NULL when the denominator '
'is zero.';
