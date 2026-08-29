# Statistical Semantics

pg_flight_recorder is a sampling instrument. Every number it reports is an estimate with a resolution limit, a selection function, and an error model. This document states those semantics in general terms; it does not restate what's captured or how each column is classified, because both now live in generated, queryable form elsewhere (see below), and a hand-maintained copy here would drift from them.

Written for practitioners, not statisticians. Every claim is computable in plain SQL against your own install.

## Contents

- [Why sample at all](#why-sample-at-all)
- [Where the census and taxonomy live](#where-the-census-and-taxonomy-live)
- [The three measurement modes](#the-three-measurement-modes)
  - [Mode A: point-in-time state sampling](#mode-a-point-in-time-state-sampling)
  - [Mode B: cumulative-counter differencing](#mode-b-cumulative-counter-differencing)
  - [Mode C: debounced state-change capture](#mode-c-debounced-state-change-capture)
- [Detection limits are relative to the active profile](#detection-limits-are-relative-to-the-active-profile)
- [Error and censoring rules](#error-and-censoring-rules)
- [Scope](#scope)

## Why sample at all

The alternative to sampling is exhaustive event logging, for example `log_min_duration_statement = 0`. Exhaustive logging looks like ground truth but is not: it has an observer effect (every event pays a logging cost), and under load the logging pipeline itself drops or backpressures events. Its selection function is load-dependent and undocumented, and it degrades precisely under the conditions of greatest interest. Fixed-cadence sampling with a stated error model is the more truthful instrument, because its blind spots are known, constant, and published.

This is a well-worn trade. Oracle's Active Session History estimates DB time as sample count times sampling interval. `pg_wait_sampling` and `pg_ash` apply the same idea natively in PostgreSQL. PostgreSQL's own planner runs entirely on `ANALYZE`'s sampled statistics. pg_flight_recorder adopts the same posture: publish the selection function, state the detection limits, and never present an estimate as a count. The observer effect itself is measured rather than assumed: `pgfr_analyze.self_overhead()` reports the recorder's own per-tier tick duration, share of block traffic, and storage footprint, self-measured at call time rather than argued from first principles.

## Where the census and taxonomy live

Two things that used to require a hand-maintained document are now generated, and are more trustworthy read live than copied here:

- **What's captured, at what cadence, with what retention, and why**: `pgfr_record.manifest`, one row per capture target. Query it directly (`SELECT source_view, cadence_tier, retention, debounce, notes FROM pgfr_record.manifest WHERE enabled`), or see [REFERENCE.md](REFERENCE.md#the-manifest) for the full census by group.
- **Per-column semantic classification** (counter, odometer, gauge, label, key) and reset linkage: `pgfr_record.column_classes`, or run `\d+` on any presentation view. `generate_comments()` writes the class directly into the column comment, so the schema is self-documenting without this file open alongside it.

Both are mechanically derived, not hand-typed, and both can change (a new PostgreSQL major adding a column, an operator disabling a manifest row) without this document going stale, because this document no longer asserts either.

## The three measurement modes

Every column pg_flight_recorder exposes falls into one of three modes, determined by the manifest row that captures it.

### Mode A: point-in-time state sampling

Manifest rows with `debounce = false` and a non-empty result set per capture (Group C: `pg_stat_activity`, `pg_locks`, replication and progress views) record what is happening *at the capture instant*, on every tick of their tier regardless of change. This is ASH-style sampling: each row is a Bernoulli observation of instantaneous state.

**Detection probability.** A condition of duration `d`, sampled at a tier's interval `T`, is captured with probability approximately `min(d/T, 1)` per occurrence. If it recurs `m` times in a window, the probability of catching it at least once is `1 - (1 - d/T)^m`.

**What Mode A cannot do: count events.** Ten 1-second lock waits and one 10-second lock wait are indistinguishable at a given cadence; both contribute about the same amount of expected sampled state. Sample counts estimate *time*, never *frequency*.

**Time-in-state estimation.** A state appearing in `k` of `n` samples over a window has estimated time-in-state `k * T`. The proportion `p_hat = k/n` carries binomial standard error `sqrt(p_hat * (1 - p_hat) / n)`.

This limit reaches into any check built on a single instant of Mode A data, not just direct queries against it: `pgfr_analyze.anomaly_report()`'s current-state checks (idle-in-transaction, lock contention, connection leaks) read `pgfr_record.state_as_of(t)` at one instant, so a condition that starts and ends between two fast-tier ticks can go unflagged with exactly the detection probability above, whatever the analysis layer's own threshold happens to be.

### Mode B: cumulative-counter differencing

Manifest rows whose columns are classified `counter` or `odometer` in `column_classes` (Group A/B: `pg_stat_database`, `pg_stat_wal`, `pg_stat_all_tables`, and the rest) integrate exhaustively inside PostgreSQL itself, in constant memory, regardless of capture cadence. `pgfr_record.deltas(source_view, from_t, to_t)` differences two captures.

**Totals are exact.** Differencing two captures yields the exact total over the interval; nothing between them is missed, because the counter never stopped counting. `delta / delta_t` is a mean rate; peak rate and sub-interval timing are unobservable, the same limitation any counter-based measurement has.

**Resets are handled, not just documented.** `deltas()` is reset-aware: a decreased counter value, or an advance in its linked `reset_column` (from `column_classes`), yields `NULL` for that interval rather than a negative or fabricated rate. Odometers (LSNs, XIDs) skip reset detection by definition, since they don't reset. This is enforced in the function itself, not left to the reader to guard against by hand.

### Mode C: debounced state-change capture

Manifest rows with `debounce = true` (Group B and Group D) append a row for a key only when its compared payload changes since that key's most recent capture, within the current anchor window, plus an unconditional full capture at every anchor.

This is not sampling in the Mode A sense: every tick performs a full comparison against the live source, so the *absence* of an appended row between two present ones means "unchanged for that whole span," not "not observed." `pgfr_record.state_as_of(source_view, t)` reconstructs a key's value at any `t` via LOCF (last-observation-carried-forward), bounded by the containing anchor. The one blind spot this mode shares with Mode A: a value that changes and changes back again between two ticks, with no anchor in between, is invisible, exactly as a Bernoulli sample would miss it. For monotonically-behaved counters and slowly-changing state (what Group B and Group D actually hold), this is a narrow, well-understood gap, not a general limitation on the reconstruction.

## Detection limits are relative to the active profile

Cadence tiers are configurable per profile (see [REFERENCE.md](REFERENCE.md#profiles)), so a detection limit is a function of whichever tier interval is currently in effect, not a fixed constant. Compute it from `pgfr_record.profile_tiers.tier_interval` for the applied profile, or from `cron.job.schedule` directly. Worked example at the `default` profile's fast-tier interval (`T = 60s`, covering Group C's Mode A targets):

| What is happening | Detection probability at 60s cadence |
|---|---|
| One 6-second lock wait | about 10% |
| One 30-second lock wait | 50% (the coin-flip point is `d = T/2`) |
| One 57-second lock wait | about 95% |
| Ten 6-second lock waits in the window | about 65% (`1 - 0.9^10`) |

Applying the `troubleshooting` profile tightens the fast tier to `T = 20s`, which is the profile's entire purpose: a 6-second wait's detection probability rises from about 10% (`6/60`) to 30% (`6/20`), with no schema or query change required.

## Error and censoring rules

1. **No proportion without its denominator.** A Mode A proportion is meaningless without the sample count behind it. `pgfr_record.health_check()`'s `ledger_miss_rate_1h` check reports both the miss count and the total in its `detail` text for exactly this reason.
2. **Coverage is queryable, not asserted.** `pgfr_record.ledger_runs` and `ledger_captures` are the raw record of every tier run and every per-target outcome: `outcome <> 'ok'` rows in `ledger_captures`, joined to `ledger_runs` for the timestamp, are exactly the gap list. `pgfr_analyze.coverage()` and `coverage_gaps()` compute this directly from the live pg_cron schedule rather than a hardcoded tick assumption, and are the form any report or dashboard should actually query.
3. **Censoring is flagged, not smoothed.** A counter reset, mid-flight, is not a noisy measurement; it's not a measurement. `deltas()` returns `NULL` rather than a negative or interpolated value across one, per Mode B above. The reset itself is visible directly in the affected source view's own `stats_reset` column, captured like any other value.
4. **Retention is a resolution limit, stated as one.** A window whose start predates a target's retention horizon does not "come back empty"; it comes back with whatever survived partition drop, which is exactly what the manifest's own `retention` column documents per target.

## Scope

SQL-native statistics only: proportions, binomial errors, and deltas, all computable in a `SELECT`. No bootstrap, no Bayesian machinery, no external statistics runtime. Reconstructing sub-interval event counts from Mode A data is not a missing feature; it is mathematically impossible at any fixed sampling cadence, documented here rather than worked around.
