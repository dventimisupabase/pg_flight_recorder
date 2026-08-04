# Statistical Semantics

pg_flight_recorder is a sampling instrument. Every number it reports is an estimate with a resolution limit, a selection function, and an error model. This document is the canonical statement of those semantics: what each class of number means, what the instrument systematically cannot see, and how sure you can be of what it shows you. Reports and reference docs link here rather than restating these definitions.

Written for practitioners, not statisticians. Every formula comes with a worked example at the recorder's fixed 60-second cadence, and everything here is computable in plain SQL.

## Why sample at all

The alternative to sampling is exhaustive event logging, for example `log_min_duration_statement = 0`. Exhaustive logging looks like ground truth but is not: it has an observer effect (every event pays a logging cost), and under load the logging pipeline itself drops or backpressures events. Its selection function is load-dependent and undocumented, and it degrades precisely under the conditions of greatest interest. Fixed-cadence sampling with a stated error model is the more truthful instrument, because its blind spots are known, constant, and published.

This is a well-worn trade. Oracle's Active Session History estimates DB time as sample count times sampling interval. `pg_wait_sampling` and `pg_ash` apply the same idea natively in PostgreSQL. PostgreSQL's own planner runs entirely on `ANALYZE`'s sampled statistics. Distributed tracing systems sample tails rather than logging every span. Astronomical surveys make the discipline explicit: a survey publishes its completeness limit and selection function alongside its catalog, and photometry (integrating flux over an exposure) coexists with photon counting as distinct measurement modes with distinct semantics. pg_flight_recorder adopts the same posture: publish the selection function, state the detection limits, and never present an estimate as a count.

## The two measurement modes

The recorder uses two statistically distinct collection mechanisms. Everything else in this document follows from the difference between them.

### Mode A: point-in-time state sampling

`pgfr_record.sample_ring()` runs once per minute (the `pgfr_sample_ring` cron job) and records what is happening *at that instant*: wait events, active sessions, and lock-blocking pairs, written to the ring-buffer partitions `wait_samples`, `activity_samples`, and `lock_samples`. This is ASH-style sampling. Each row is a Bernoulli observation of instantaneous state: at tick `t`, either the condition was occurring or it was not.

The ring holds roughly 2 to 4 hours at defaults (3 slots on a 2-hour rotation). When a slot rotates out, `rotate_ring()` flushes it as aggregate rollups into the durable archive tables (`wait_event_rollups_archive_v2`, `lock_rollups_archive_v2`, `activity_rollups_archive_v2`), retained for `retention_archive_days` (7 days by default).

**Detection probability.** A condition of duration `d` sampled at interval `T` is captured with probability approximately `min(d/T, 1)` per occurrence. At the 60 s cadence, a 6-second lock wait has about a 10% chance of appearing in any one pass. If it recurs `m` times in a window, the probability of catching it at least once is `1 - (1 - d/T)^m`: ten independent 6-second waits have about a 65% chance of showing up at all.

**Time-in-state estimation.** A state appearing in `k` of `n` samples over a window has estimated time-in-state `k * T`. The proportion `p_hat = k/n` carries binomial standard error `sqrt(p_hat * (1 - p_hat) / n)`. `pgfr_analyze.wait_summary()`'s `pct_of_samples` is exactly this estimator's proportion: distinct ticks where the wait appeared, over distinct ticks that recorded any wait data in the window, times 100. The archive rollups' `pct_of_samples` uses the same definition. Neither is a share of waiters; `total_waiters` measures volume separately.

**What Mode A cannot do: count events.** Ten 1-second lock waits and one 10-second lock wait are indistinguishable at 60 s cadence; both contribute about 10 seconds of expected sampled state. Sample counts estimate *time*, never *frequency*. Any report language implying event counts from Mode A data is a semantic bug. Reconstructing sub-interval event counts from Mode A data is not a missing feature; it is mathematically impossible at this cadence, and the recorder does not attempt it.

### Mode B: cumulative-counter differencing

The per-minute `pgfr_snapshot` cron job captures monotonically increasing counters from PostgreSQL's cumulative statistics system into `snapshots_v2`, `statement_snapshots_v2`, `consumption_snapshots_v2`, and the table/index snapshot tables. Consumers read these as deltas: `consumption_deltas`, `consumption_flows`, and the `*_activity_v2` reader functions all difference consecutive snapshots.

**Totals are exact.** The counters integrate exhaustively, in constant memory, inside PostgreSQL itself. Differencing two snapshots yields the exact total over the interval. This is integral sampling: nothing between the snapshots is missed, because the counter never stopped counting. The one caveat is counter resets (crash, explicit reset, `pg_stat_statements` eviction), which are censoring events, not noise; deltas spanning them are invalid and must be suppressed, never smoothed over (see the selection-function catalog and the error model below).

**Within-interval shape is lost.** `delta_C / delta_t` is the *mean* rate over the interval. Peak rate, burstiness, and sub-interval timing are unobservable. All `*_per_s` columns (`block_demand_per_s`, `wal_bytes_per_s`, `xact_per_s`, and the rest of `consumption_flows`) are interval-mean rates, never instantaneous ones. A 10-second burst at 6x the mean and a steady flow produce identical deltas over a minute.

## Column taxonomy

Every column the recorder exposes classifies as exactly one of four semantic types:

| Type | Definition | Error model | Examples |
|---|---|---|---|
| **Point sample** | Mode A Bernoulli observation of instantaneous state | Binomial; estimates time-in-state, never event counts | `wait_samples` rows, `sample_count`, `pct_of_samples`, `total_waiters` |
| **Counter delta** | Difference of a cumulative counter between two snapshots | Exact over the interval, modulo resets; mean rate only | `calls_delta`, `blks_read_delta`, `wal_bytes_delta`, all `*_per_s` columns |
| **Gauge** | Instantaneous level read at snapshot time | Exact at the sample instant, undefined between samples | `datfrozenxid_age`, `datminmxid_age`, `db_size_bytes`, `connections_active`, xmin-horizon ages on the legacy `snapshots` table |
| **Derived estimate** | Computed from the above; inherits and propagates their semantics | Follows from inputs (a ratio of deltas is exact; a ratio involving a point sample is an estimate) | `hit_ratio_pct`, `recorder_overhead_fraction`, `mean_exec_time_ms`, trend slopes |

The per-column classification is not maintained in this document. It lives in the schema itself: every user-facing view column carries a `COMMENT ON COLUMN` with a machine-parseable `[class] [units]` prefix, set-returning functions carry an `Output columns:` block in their function comment, and `pgfr_analyze.column_semantics()` returns the parsed registry (one row per column: relation, column name, semantic class, units, interval basis, notes). That registry is the source of truth for what any given column means; `\d+` on a view shows the same annotations inline.

Two consequences worth internalizing:

- A gauge sampled every minute is a strip chart with 60-second pixels. `connections_active` can spike and fully recover between ticks without leaving a trace. Gauges share Mode A's detection limit even though each reading is exact.
- Derived estimates are only as good as their weakest input. `mean_exec_time_ms` (a ratio of two exact deltas) is exact for the interval; a "percent of time blocked" figure built on Mode A samples carries the full binomial error of its numerator.

## The selection-function catalog

What the instrument systematically cannot see. This list is canonical: report language must never contradict it.

1. **Short-lived session bias (Mode A).** Sessions and queries shorter than the sampling interval are undersampled in proportion to their duration. A workload of 200 ms queries is nearly invisible to `activity_samples` no matter how many run; the instrument is biased toward long-running state. That bias is also the point: long-running state is what sampling is for, and Mode B's counters cover the short-query workload exactly (calls, time, blocks) even though no individual short query is ever observed.

2. **Duration-weighting of wait events (Mode A).** Sample counts weight by time, not occurrence. A wait that is rare but long dominates one that is frequent but short, even if the short one fires a thousand times more often. This is correct behavior for a time-in-state instrument and a trap for anyone reading `sample_count` as popularity.

3. **`pg_stat_statements` eviction (Mode B).** When the statement cache saturates, low-frequency queries are evicted between snapshots; their deltas are silently lost or misattributed to a later re-entry. Statistically this is right-censoring of the query population, and it is not uniform: the stratum that goes missing is exactly the low-call-count tail. `pgfr_record._check_statements_health()` tracks the mechanism (utilization and dealloc counts), collection is skipped entirely under `HIGH_CHURN`, and `statement_snapshots_v2.pgss_dealloc_warning` flags ticks where eviction occurred; `statement_activity_v2()` surfaces it as `pgss_reset_warning`. When that flag is set, absence of a query from the report is not evidence of absence from the workload.

4. **Circuit-breaker and cron gaps (missingness that correlates with load).** `pgfr_record._check_circuit_breaker()` skips a collection pass when the recent average runtime of that collector exceeds a threshold (by default, the last 3 successful runs averaged over a 15-minute window against `circuit_breaker_threshold_ms` = 1000). Load shedding does the same when the active-backend fraction is high, and pg_cron itself can miss ticks on an overloaded system. The consequence: samples go missing *because* the system was under stress. Gaps are informative missingness (MNAR, missing not at random), correlated with exactly the states you are trying to observe. Gaps are first-class data. They must be shown, attributed, and never silently interpolated over.

5. **Restart discontinuities.** A crash or restart resets cumulative counters and truncates ring state. Post-restart windows have a different baseline, and a naive delta across the boundary is garbage (typically a huge negative number, or a plausible-looking small positive one, which is worse). `consumption_deltas` guards its lanes against observed resets, and trend logic must treat restarts as changepoints by construction, not as outliers to smooth.

6. **Ring-buffer grain horizon.** The ring window (about 2 to 4 hours at defaults) is a resolution limit, not a data loss. `rotate_ring()` flushes each outgoing slot into the durable archive tables before truncating, so Mode A's time-in-state estimators (`sample_count`, `pct_of_samples`, waiter counts) cross the boundary intact as one aggregate row per rotation window, retained for `retention_archive_days` (7 days default). What is lost at the boundary is *grain*: per-session identity, query previews, cross-dimension joint structure, and any timing finer than the rotation period. Genuine data loss occurs in exactly two places: archive retention expiry (documented policy), and the flush-failure path, where `rotate_ring()` deliberately truncates the slot even if the rollup flush fails (ring safety takes priority over rollup completeness), destroying that slot's samples with only a log warning. That failure is a censoring event and should be recorded as one.

7. **Observer effect.** The recorder measures the system it perturbs. Its own queries appear in `pg_stat_statements`, its writes generate WAL and I/O, and its reads occupy buffer cache. The instrument measures its own footprint: `consumption_snapshots_v2.recorder_blks_hit` and `recorder_blks_read` track block traffic against the recorder's own schema, and `consumption_flows.recorder_overhead_fraction` reports it as a share of total block demand. The overhead is designed to be small and, more importantly, *constant*: a fixed cadence costs the same at idle and under load, unlike exhaustive logging whose cost scales with the workload.

## The error and missing-data model

Four rules govern how the recorder's numbers must be presented and read.

### 1. No proportion without its denominator

A Mode A proportion is meaningless without the number of samples behind it. `wait_summary()` exposes `sample_count`; the window's total tick count is the denominator of `pct_of_samples`. Where an uncertainty interval is warranted, both the binomial normal approximation and the Wilson interval are one-line SQL:

```sql
-- k = samples where the state appeared, n = total samples in the window
with obs as (select 3::numeric as k, 60::numeric as n, 1.96 as z)
select
    k / n                                          as p_hat,
    sqrt((k / n) * (1 - k / n) / n)                as se_binomial,
    (k/n + z*z/(2*n) - z * sqrt((k/n)*(1 - k/n)/n + z*z/(4*n*n))) / (1 + z*z/n) as wilson_low,
    (k/n + z*z/(2*n) + z * sqrt((k/n)*(1 - k/n)/n + z*z/(4*n*n))) / (1 + z*z/n) as wilson_high
from obs;
```

For `k = 3`, `n = 60` this returns `p_hat = 0.05`, standard error about `0.028`, and a 95% Wilson interval of about `[0.017, 0.137]`. The normal approximation is fine for `k` above about 10; Wilson behaves properly at small `k`, including `k = 0`.

### 2. Coverage is a reported quantity

Every windowed estimate should be readable alongside `observed_samples / expected_samples` for its window, with the gap list and attributed reasons. A `pct_of_samples` computed over a window with 40% coverage is an estimate about the covered minutes only, and the missing minutes are biased toward stress (catalog item 4).

`pgfr_analyze.coverage(start, end)` reports expected versus observed ticks per collector at the fixed one-minute cadence, and `pgfr_analyze.coverage_gaps(start, end)` lists each gap with an attributed reason: `retention_horizon` (the tick predates the oldest evidence still retained), `circuit_breaker` and `load_shedding` (skip evidence recorded at collection time), `restart` (the unobserved run leading into the postmaster start time), `cron_inactive`, or `unknown`. Report functions qualify their conclusions when any collector's retention-adjusted coverage falls below **90%** for the window (retention truncation is a resolution limit, not missed collection, so it does not count against confidence). Gaps attributed to the circuit breaker or load shedding always trigger the missing-not-at-random caveat regardless of the overall ratio: collection was skipped because the system was under stress, so absence of samples is not absence of activity.

### 3. Censoring is flagged, not smoothed

Counter resets, `pg_stat_statements` evictions, restarts, and ring flush failures are censoring events. A delta that spans one is not a noisy measurement; it is not a measurement. The correct output is NULL with an attributed reason, never an interpolated value.

The recorder keeps these events as first-class data in `pgfr_record.discontinuities` (one row per detected reset, restart, eviction-pressure episode, or ring flush failure, with machine-readable evidence). The `*_activity_v2` readers return NULL deltas with a `censored_reason` column (`no_baseline` or `counter_regression`) instead of clamped or lifetime-counter values; the trend engines classify a level shift that lands on a recorded restart or reset as `discontinuity` (a known instrument boundary) rather than a discovered changepoint; and `coverage_gaps()` attributes blackout runs to recorded restarts.

### 4. Detection limits are stated in advance

The instrument's blind spots are computable before any data arrives, and stating them converts "the report did not show it" into "no detection above threshold X". The resolution tables below are computed for the operative cadence, which is a fixed 60 seconds for both cron jobs (hardcoded `* * * * *`; the `sample_interval_seconds` config key does not change it).

#### Mode A resolution: event duration to detection probability

Per occurrence, `P(detect) = min(d/T, 1)` for duration `d` at cadence `T = 60 s`. For `m` occurrences, `P(at least one) = 1 - (1 - d/T)^m`; for a condition active a steady fraction `p` of a window of `n` ticks, `P = 1 - (1 - p)^n`.

| What is happening | Detection probability at 60 s cadence |
|---|---|
| One 6-second lock wait | about 10% |
| One 30-second lock wait | 50% (the coin-flip point is `d = T/2`) |
| One 57-second lock wait | about 95% |
| Ten 6-second lock waits in the window | about 65% (`1 - 0.9^10`) |
| A condition active 5% of the time, over one hour (`n = 60`) | about 95% (`1 - 0.95^60`) |
| A condition active 5% of the time, over 24 hours (`n = 1440`) | indistinguishable from certain |

So the direct answer to "what is the shortest lock storm this will reliably see?": a single continuous wait needs about 30 seconds for even odds and about 57 seconds for 95%; a recurring storm needs to be active about 5% of the time for an hour to be seen with 95% probability. Anything shorter and rarer is below the instrument's resolution, and its absence from a report means nothing.

Estimation precision after detection follows the binomial error: a condition seen in `k` of `n` ticks has `p_hat = k/n` with standard error `sqrt(p_hat (1 - p_hat) / n)`; at `p = 0.05` over one hour the SE is about `0.028`, so 5% presence is barely two SEs from zero, while over 24 hours the same presence is measured to about a tenth of its value.

#### Trend-layer resolution: minimum detectable movement

The consumption trend engines are fit-gated, not magnitude-gated, and their sensitivity is fixed by configuration: `consumption_trend_min_days = 14` (daily) and `consumption_trend_min_weeks = 8` (weekly) before anything is classified at all; `consumption_trend_min_r2 = 0.3` before any movement is flagged; a step must beat the best line by an R-squared margin of `consumption_trend_step_r2_margin = 0.15`; each step segment needs at least 3 points; and the composition guard vetoes attribution when the workload-shape indicators move more than `consumption_trend_shape_guard_pct = 25%` between the window's fixed halves. Slopes are Theil-Sen medians normalized to percent per 30 days.

The `R^2 >= 0.3` gate translates to a magnitude: a linear drift is flaggable once its total movement over the window reaches about `2.2` times the point-to-point noise standard deviation (from `R^2 = signal/(signal + noise)`, a clean ramp over `n` evenly spaced points needs total drift `(n-1) * sigma * sqrt((0.3/0.7) * 12/(n^2-1))`, which is about `2.2 sigma` at both `n = 28` daily and `n = 12` weekly points). Movements smaller than that classify `stable`, and `stable` therefore means "no movement above about two noise standard deviations", not "nothing changed". Recorded restarts and stats resets enter as known segment boundaries (`discontinuity` classification), never as discovered changepoints.

## Worked example: reading a wait report

*"My report shows lock waits in 3 of 60 samples over the last hour. What does that mean, and how sure am I?"*

- **Estimated time-in-state:** `k * T = 3 * 60 s`, so about 3 minutes of the hour had a lock wait in progress. This is the headline number and the only duration claim the data supports.
- **Uncertainty:** `p_hat = 3/60 = 0.05` with binomial standard error `sqrt(0.05 * 0.95 / 60)`, about `0.028`. The 95% Wilson interval is roughly `[0.017, 0.137]`, so the true time-in-state is plausibly anywhere from about 1 minute to about 8 minutes of the hour. Three samples is a weak signal; treat it as "lock waits were present, roughly minutes not seconds," not as a precise figure.
- **What you cannot conclude:** the number of distinct lock waits. Three samples is equally consistent with one 3-minute wait, three unrelated waits of a minute each, or dozens of shorter waits that mostly fell between ticks (each 6-second wait had only a 10% chance of being seen). Mode A estimates time, never frequency. If you need event counts, you need a different instrument (for example `log_lock_waits`), with its own observer costs.
- **Before trusting it:** check coverage for the window. If several of the 60 expected ticks are missing, the gaps are more likely during the stress you care about (catalog item 4), and 3-of-57 over a gappy hour reads differently from 3-of-60 over a clean one.

## The instrument's own cost

Observer effect is part of the error model, and stating it is the strongest credibility signal available. The budget is self-measured and queryable at any time: `pgfr_analyze.self_overhead()` returns each figure with the exact method used to compute it, from the recorder's own tables, so the numbers below are re-derivable on any install rather than trusted from a benchmark.

- **Collection time per tick.** Every run's wall time lands in `collection_stats.duration_ms`; `self_overhead()` reports the 24-hour average per collector. Hard ceilings are enforced by the cron jobs' statement timeouts: 500 ms for the ring sampler, 10 s for the snapshot. The circuit breaker turns a sustained budget overrun (average of the last 3 runs above `circuit_breaker_threshold_ms`, default 1000 ms) into skipped ticks rather than added load, so the cost is bounded under exactly the conditions where it would matter most.
- **Buffer traffic.** `consumption_snapshots_v2.recorder_blks_hit`/`recorder_blks_read` isolate block traffic against the recorder's own schema, and `consumption_flows.recorder_overhead_fraction` reports it as a share of the database's total block demand each tick; `self_overhead()` reports the 24-hour average share.
- **Its own queries.** The recorder's statements appear in `pg_stat_statements` like everyone else's; `self_overhead()` reports the pgfr-attributed share of total execution time since the last statistics reset. This share is part of the population the statement snapshots sample, and it is not filtered out: the instrument appears in its own reports.
- **Storage.** Total on-disk footprint of both schemas, including indexes and TOAST. Retention settings bound it (ring rotation, `retention_snapshots_days`, `retention_archive_days`), so it converges instead of growing without limit; the exceptions with no retention (`consumption_trends`, `discontinuities`) are tiny by construction.

The structural point: a fixed-cadence instrument costs the same at idle and under load. Exhaustive logging's cost scales with the workload and peaks exactly when the system can least afford it; the recorder's per-tick cost is constant, capped, and self-reported.

## Glossary

- **Sample**: one Mode A observation, a point-in-time reading of instantaneous state taken at a cron tick.
- **Snapshot**: one Mode B capture of cumulative counters (plus gauges) at a cron tick; meaningful mainly as one endpoint of a delta.
- **Gauge**: an instantaneous level (age, size, count) read at snapshot time; exact at that instant, undefined between ticks.
- **Delta**: the difference of a cumulative counter between two snapshots; an exact total for the interval, carrying only mean-rate information.
- **Estimator**: the rule that turns raw observations into a reported quantity, for example `k * T` for time-in-state or `delta_C / delta_t` for mean rate. Every reported column has one, stated or not; this document states them.
- **Coverage**: observed samples divided by expected samples for a window; the fraction of the window the instrument actually saw.
- **Censoring**: an event (counter reset, eviction, restart, flush failure) that invalidates measurements spanning it; censored intervals are flagged NULL-with-reason, never interpolated.
- **Selection function**: the probability that a phenomenon, given that it occurred, appears in the data; the seven-item catalog above is the recorder's selection function in prose.
- **Detection limit**: the smallest effect (duration, rate change, presence fraction) the instrument can distinguish from nothing at its cadence and window size; computable in advance from the error model.

## Scope

SQL-native statistics only: proportions, binomial errors, Wilson intervals, and deltas, all computable in a `SELECT`. No bootstrap, no Bayesian machinery, no external statistics runtime. Reports are not statistics lectures: they carry one-line qualifications and link here. And one non-goal, restated because it is the most common wish: reconstructing sub-interval event counts from Mode A data is fundamentally impossible at the sampling cadence and is documented here instead of worked around.
