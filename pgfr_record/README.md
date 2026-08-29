# pgfr_record

Core extension of [pg_flight_recorder](https://github.com/dventimisupabase/pg_flight_recorder). Continuously appends PostgreSQL's own stats views and system views into time-partitioned tables, so you can answer "what was happening in my database?" after the fact, without adding an external agent, sidecar, or polling process.

## Contents

- [The pitch](#the-pitch)
- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Profiles](#profiles)
- [Testing](#testing)
- [Upgrade](#upgrade)
- [Uninstall](#uninstall)
- [Related](#related)

## The pitch

PostgreSQL's cumulative stats system gives you the integral: a running total since the last reset. The system catalogs give you the latest: the current state, with no history. `pgfr_record` gives you the derivative over the stats and the history over the catalogs, by sampling both on a schedule and keeping the samples. The data model is not invented; it is exactly the tables and views already documented in the PostgreSQL manual, presented as a time series.

A few things follow from that, and they are the reasons to install this rather than something else:

- **Append-only, everywhere.** No `UPDATE`, no `DELETE`, anywhere in this schema. Retention is partition drop, never a `DELETE` statement. A crash mid-capture leaves no partial row, ever.
- **The record/analyze boundary, and the agent test.** Everything with a single correct answer (what was captured, its shape, what kind of quantity each column is, how identity resolves over time) lives here, in `pgfr_record`. Everything requiring a threshold or an opinion belongs in the optional `pgfr_analyze` extension. The proof of that boundary is the agent test (`scripts/agent_test.sh`): dump `pgfr_record` alone, restore it into an empty database on a *different* PostgreSQL major version, regenerate the typed views offline from the stored payload dictionary with no live source views to copy from, and answer real troubleshooting questions using nothing but psql. That script passes today.
- **Static bounds, always recorded.** `lock_timeout` bounds each target's lock wait, `job_timeout` bounds a tier's total run time, and a capture ledger records every miss with its reason. This keeps the recorder valuable exactly when an incident makes it most valuable: it degrades in a bounded, visible way rather than going dark. `pg_cron` never runs two instances of the same tier job concurrently, so those bounds alone are enough to keep collection predictable.
- **One design artifact.** Every archive table, presentation view, capture-plan entry, and column classification is generated from a single table, `pgfr_record.manifest`, plus the live catalog. Re-running `install.sql` regenerates all of it; that is the entire upgrade procedure, including after a PostgreSQL major version upgrade.
- **Record is sufficient; analyze is acceleration.** A `pgfr_record`-only install, or a `pg_dump` of one, is fully self-contained and self-describing: typed presentation views, a column-class legend, identity resolution across time, definitional helpers, and generated `COMMENT ON` for every object so `\d+` explains itself. The optional `pgfr_analyze` extension makes conclusions faster; nothing an agent needs to reach a conclusion lives only there.

See [REFERENCE.md](../REFERENCE.md) for the full technical reference: every table, view, and function, what it means, and how to use it.

## Requirements

- PostgreSQL 15, 16, 17, or 18
- The `pg_cron` extension
- Optional: `pg_stat_statements`, for per-query capture (the corresponding manifest rows are skipped with a `NOTICE`, not an error, when it's absent)

## Install

Three channels, matching the three ways this repo ships the extension:

**psql**, from a checkout of this repo. Runs `install.sql`'s `\ir` includes directly:

```bash
psql --single-transaction -f pgfr_record/install.sql
```

**Bundle**, a self-contained single SQL file with no psql metacommands, for clients that can't process `\ir` (a SQL editor, for example the Supabase dashboard). Build it from a checkout, or download the bundle from a [GitHub release](https://github.com/dventimisupabase/pg_flight_recorder/releases/latest):

```bash
./scripts/build_install_bundle.sh pgfr_record dist/pgfr_record-bundle.sql
```

The bundle wraps itself in `BEGIN`/`COMMIT`, so paste it whole into a SQL editor and run it.

**dbdev**, via [database.dev](https://database.dev):

```sql
select dbdev.install('dventimi@pgfr_record');
```

All three install the same objects. `install.sql` finishes by calling `pgfr_record.enable()`, so collection starts immediately after install; nothing before that point schedules any pg_cron job.

## Quick start

```sql
-- Confirm collection is running: cron jobs active, recent captures per tier,
-- ledger miss rate, and partition-maintenance status.
SELECT * FROM pgfr_record.health_check();

-- See what's actually captured, at what cadence, and why.
SELECT source_view, cadence_tier, retention, notes FROM pgfr_record.manifest WHERE enabled ORDER BY cadence_tier;

-- Read a typed presentation view like any other PostgreSQL stats view.
SELECT * FROM pgfr_record.v_pg_stat_database ORDER BY captured_at DESC LIMIT 10;
```

## Profiles

```sql
SELECT pgfr_record.apply_profile('troubleshooting'); -- tighter fast/medium cadence for active incident work
SELECT pgfr_record.apply_profile('default');         -- back to steady-state cadence
SELECT pgfr_record.disable();                        -- stop all collection (data, manifest, and capture plan untouched)
SELECT pgfr_record.enable();                          -- resume with the default profile
```

See [REFERENCE.md](../REFERENCE.md#profiles) for the exact cadence and timeout values each profile sets.

## Testing

```bash
./test.sh              # all PostgreSQL versions (15-18), all three install channels
./test.sh 17            # one version, all channels
./test.sh --channel=psql # all versions, one channel
```

## Upgrade

Re-run `install.sql` (or the equivalent bundle/dbdev channel). Every generator function is safe to re-run: it regenerates archive tables, presentation views, the capture plan, and column classes against whatever the live catalog looks like now, and history is untouched. This is also the procedure after a PostgreSQL major version upgrade.

## Uninstall

```bash
psql --single-transaction -f pgfr_record/uninstall.sql
```

Unschedules every `pgfr_*` pg_cron job and drops the `pgfr_record` schema (and, if installed, `pgfr_analyze`) with `CASCADE`. Destructive: this removes all captured data.

## Related

- [Top-level README](../README.md): project overview and the two-extension structure.
- [REFERENCE.md](../REFERENCE.md): full technical reference.
- [STATISTICS.md](../STATISTICS.md): what's collected and why, and the manifest census in more detail.
- [pgfr_analyze](../pgfr_analyze/README.md): the optional reporting/analysis extension.
