# pgfr_analyze

Optional analysis extension of [pg_flight_recorder](https://github.com/dventimisupabase/pg_flight_recorder). Reads `pgfr_record`'s captured data, column classes, and definitional helpers to answer questions that need a threshold, a baseline, or an opinion; never writes to the core schema.

## Contents

- [The pitch](#the-pitch)
- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Testing](#testing)
- [Uninstall](#uninstall)
- [Related](#related)

## The pitch

`pgfr_record` captures what happened. `pgfr_analyze` decides whether it matters. Everything with a single correct answer (what was captured, its shape, how identity resolves over time) lives in `pgfr_record`; everything here encodes a judgment call instead, built entirely on `pgfr_record.deltas()`, `pgfr_record.state_as_of()`, and `pgfr_record.column_classes`, owning none of those facts itself.

A few things follow from that:

- **Opinions are tunable, and say so.** Severity bands, lookback windows, and ratios live in `pgfr_analyze.config`, read via `_get_config(key, default)`; every function that exposes a threshold falls back to a documented default when the key is unset.
- **Two operational layers.** `preflight_check()` answers "is this system ready to install `pgfr_record`" before any history exists. `check_alerts()` and `quarterly_review()` answer "is `pgfr_record` itself still healthy" once it's running, by turning `pgfr_record.health_check()`'s judgment-free facts into alerts and grades.
- **One diagnostic pass, two shapes.** `report(from_t, to_t)` composes anomaly detection, capacity views, table and index hotspots, query regressions and storms, activity, WAL archiving, and configuration changes into a markdown report a human or an AI agent can read directly. `summary_report(from_t, to_t)` composes the same functions into a structured `(section, metric, value, interpretation)` table for a dashboard or a script to consume instead.
- **The recorder audits itself.** `self_overhead()` and `performance_report()` measure `pgfr_record`'s own tick duration, storage footprint, and share of block/query traffic, rather than assuming its overhead is negligible.
- **Bounded by raw retention, not `pgfr_record`'s longer rollup horizon.** `pgfr_record` keeps a compressed, 365-day rollup alongside several targets' shorter raw retention (see [Rollups](../REFERENCE.md#rollups)), but every function here reads raw `deltas()`/`state_as_of()` only; none of them fall back to a rollup once raw history ages out. For a longer, coarser look than anything here provides, query `pgfr_record.rollup_deltas()` directly.

See [REFERENCE.md](../REFERENCE.md#pgfr_analyze) for the full technical reference: every function, what it means, and how to use it.

## Requirements

- `pgfr_record` installed first (`pgfr_analyze/install.sql` refuses to proceed otherwise)
- Same PostgreSQL version support as `pgfr_record`: 15, 16, 17, or 18
- Optional: `pg_stat_statements`, for the query dictionary and query-level regression/storm detection. Functions that depend on a source `pgfr_record` hasn't captured yet raise a clear error rather than silently returning nothing; once running, a missing extension only affects that one target's captures, isolated via `pgfr_record`'s capture ledger.

## Install

Three channels, matching the three ways this repo ships the extension:

**psql**, from a checkout of this repo:

```bash
psql --single-transaction -f pgfr_record/install.sql
psql --single-transaction -f pgfr_analyze/install.sql
```

**Bundle**, a self-contained single SQL file for clients that can't process `\ir` (a SQL editor, for example the Supabase dashboard):

```bash
./scripts/build_install_bundle.sh pgfr_analyze dist/pgfr_analyze-bundle.sql
```

**dbdev**, via [database.dev](https://database.dev):

```sql
select dbdev.install('dventimi@pgfr_analyze');
```

All three create the `pgfr_analyze` schema, its `config` table, and every function; none of them schedule anything on their own. `pgfr_record`'s own pg_cron jobs remain `pgfr_analyze`'s only source of new data.

## Quick start

```sql
-- Before installing pgfr_record: is this system ready?
SELECT * FROM pgfr_analyze.preflight_check_with_summary();

-- After some history has accumulated: a full diagnostic report for the last hour.
SELECT pgfr_analyze.report(interval '1 hour');

-- Is pgfr_record itself healthy right now?
SELECT * FROM pgfr_analyze.check_alerts();
```

## Testing

```bash
./test.sh              # all PostgreSQL versions (15-18), all three install channels
./test.sh 17            # one version, all channels
./test.sh --channel=psql # all versions, one channel
```

## Uninstall

```bash
psql --single-transaction -f pgfr_analyze/uninstall.sql
```

Drops the `pgfr_analyze` schema with `CASCADE`. `pgfr_record/uninstall.sql` also drops it, as one of its own two `DROP SCHEMA` statements, when removing both extensions together. Destructive: this removes `query_dict` and any tuned thresholds in `pgfr_analyze.config`, though not any `pgfr_record` history.

## Related

- [Top-level README](../README.md): project overview and the two-extension structure.
- [pgfr_record/README.md](../pgfr_record/README.md): the required core extension.
- [REFERENCE.md](../REFERENCE.md): full technical reference.
