# pg_flight_recorder

[![GitHub release](https://img.shields.io/github/v/release/dventimisupabase/pg_flight_recorder)](https://github.com/dventimisupabase/pg_flight_recorder/releases/latest)
[![Test Suite](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/test.yml/badge.svg)](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/test.yml)
[![Lint](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/lint.yml/badge.svg)](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/lint.yml)

Server-side flight recorder for PostgreSQL. Answers "what was happening in my database?"

**[View the project website](https://dventimisupabase.github.io/pg_flight_recorder/)**

pg_flight_recorder continuously records PostgreSQL system state in the background via pg_cron: no external agents, sidecars, or polling. It samples wait events and active sessions once a minute, and snapshots WAL activity, checkpoints, I/O, table and index stats, query performance, replication state, vacuum progress, and configuration on the same cadence. When something goes wrong, the data is already there.

## Architecture

Two collection mechanisms run every minute, both scheduled by `pgfr_record.enable()`:

| Mechanism | Job | What it captures | Where it lands |
|-----------|-----|------------------|----------------|
| **Sampling** | `pgfr_sample_ring` (500ms timeout) | Wait events and active sessions, observed at the sample instant | Ring buffer partitions, TRUNCATE-rotated every 2 hours |
| **Snapshots** | `pgfr_snapshot` (10s timeout) | Cumulative counters and gauges: WAL, checkpoints, bgwriter, per-backend-type I/O, transactions, temp files, archiver, XID/MultiXID ages, xmin horizon attribution, replication, vacuum progress, statements, tables, indexes, configuration, consumption ledger | Daily-partitioned snapshot tables |

Just before each ring rotation destroys a slot, that slot's data is rolled up into durable, bounded-size summary tables (`wait_event_rollups_archive_v2`, `activity_rollups_archive_v2`), so trend visibility survives past the ring window as compact aggregates. There is no full-resolution downstream archive. Snapshot retention is enforced by partition truncate and drop, never DELETE.

Retention tiers at default settings:

| Tier | Contents | Retention |
|------|----------|-----------|
| Ring buffer | Raw per-minute samples (per-session detail, query previews) | 2-4 hours (3 slots, 2-hour rotation) |
| Ring rollups | Per-rotation-window wait/activity summaries | 7 days (`retention_archive_days`) |
| Snapshots | All daily-partitioned counter and gauge tables | 30 days (`retention_snapshots_days`) |
| Consumption daily rollups | One row per day per database | Indefinite (tiny by construction) |

Safety mechanisms (circuit breaker, load shedding, per-section timeouts, per-job statement timeouts) keep the recorder from impacting production workloads. See [Safety](#safety).

## Extensions

Two extensions, each published as a separate [dbdev](https://database.dev) package:

| Extension | Schema | Purpose | README |
|-----------|--------|---------|--------|
| [pgfr_record](https://database.dev/dventimi/pgfr_record) | `pgfr_record` | Core: tables, collection, scheduling, ring buffers | [pgfr_record/README.md](pgfr_record/README.md) |
| [pgfr_analyze](https://database.dev/dventimi/pgfr_analyze) | `pgfr_analyze` | Optional: reporting, anomaly detection, time travel | [pgfr_analyze/README.md](pgfr_analyze/README.md) |

`pgfr_analyze` only reads from `pgfr_record`; it never writes to the core schema.

## Requirements

- PostgreSQL 15, 16, 17, or 18 (all four tested in CI)
- `pg_cron` extension
- Optional: `pg_stat_statements` for query-level analysis (the statements collector no-ops without it)

## Quick start

Download from [GitHub Releases](https://github.com/dventimisupabase/pg_flight_recorder/releases/latest) or clone the repo, `cd` into the project root, then:

```bash
# Install core + optional analysis extension
psql --single-transaction -f pgfr_record/install.sql
psql --single-transaction -f pgfr_analyze/install.sql
```

```sql
-- Enable collection (schedules 7 pg_cron jobs)
SELECT pgfr_record.enable();

-- Verify the recorder is running
SELECT * FROM pgfr_record.health_check();

-- Generate a diagnostic report on the database
SELECT pgfr_analyze.report('1 hour');
```

Other install channels:

- **Single-file bundle**: each release ships `pgfr_record-bundle.sql` and `pgfr_analyze-bundle.sql`, self-contained files with no psql metacommands, suitable for SQL editors. The [one-click install page](https://dventimisupabase.github.io/pg_flight_recorder/install.html) wraps them.
- **dbdev**: `select dbdev.install('dventimi@pgfr_record');` and the same for `dventimi@pgfr_analyze`.

## Scheduled jobs

`enable()` schedules exactly these pg_cron jobs, each wrapped in its own `statement_timeout`:

| Job | Schedule | Timeout | Does |
|-----|----------|---------|------|
| `pgfr_sample_ring` | every minute | 500ms | Sample wait events and active sessions into the ring |
| `pgfr_snapshot` | every minute | 10s | Capture all snapshot tables |
| `pgfr_rotate_ring` | every 2 hours | 10s | Roll up and truncate the oldest ring slot |
| `pgfr_cleanup` | daily 03:00 | 60s | Legacy-table retention plus daily consumption rollup |
| `pgfr_truncate_partitions` | daily 03:00 | 30s | Truncate expired v2 partitions |
| `pgfr_drop_ancient_partitions` | monthly | 30s | Drop long-empty partitions |
| `pgfr_precreate_partitions` | daily 23:55 | 5s | Pre-create tomorrow's partitions |

`disable()` unschedules all of them; `uninstall.sql` additionally drops the schema and data.

## Common workflows

### Verifying the recorder

Confirms that collection is running, pg_cron jobs are active, the circuit breaker isn't tripping, schema size is in range, and `pg_stat_statements` (if installed) isn't churning. Run after install, after upgrades, or whenever a report looks thin.

```sql
SELECT * FROM pgfr_record.health_check();
```

### Daily monitoring

Returns a markdown report covering anomalies, wait events, top queries, and other activity over the given window. Suitable for a daily glance, or pasted into a chat with an LLM for triage.

```sql
SELECT pgfr_analyze.report('1 hour');
```

### Incident response

```sql
-- What was happening at a specific time?
SELECT * FROM pgfr_analyze.what_happened_at('2024-01-15 14:32');

-- Reconstruct an incident timeline
SELECT * FROM pgfr_analyze.incident_timeline(
    '2024-01-15 14:00',
    '2024-01-15 15:00'
);

-- Measure an incident's impact on connections, TPS, and sessions
SELECT * FROM pgfr_analyze.blast_radius(
    '2024-01-15 14:00',
    '2024-01-15 15:00'
);
```

### XID / MultiXID wraparound monitoring

```sql
-- Current XID and MultiXID ages at database level (from the latest snapshot)
SELECT datfrozenxid_age, datminmxid_age
FROM pgfr_record.snapshots
ORDER BY captured_at DESC LIMIT 1;

-- Wraparound anomalies (XID + MultiXID, cluster + per-table)
SELECT anomaly_type, severity, metric_value, recommendation
FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())
WHERE anomaly_type LIKE '%WRAPAROUND%';

-- Tune thresholds (lower warning ratio to alert earlier on busy clusters)
INSERT INTO pgfr_record.config (key, value) VALUES
    ('xid_warning_ratio',  '0.25'),
    ('mxid_warning_ratio', '0.25')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
```

See [REFERENCE.md](REFERENCE.md#xid--multixid-wraparound-thresholds) for the full config key list and rationale.

### Performance analysis

```sql
-- Find performance regressions
SELECT * FROM pgfr_analyze.detect_regressions('1 day');

-- Find query storms
SELECT * FROM pgfr_analyze.detect_query_storms('1 hour');

-- Table hotspots
SELECT * FROM pgfr_analyze.table_hotspots(now() - interval '1 day', now());

-- Unused indexes
SELECT * FROM pgfr_analyze.unused_indexes('7 days');
```

### Consumption trends

The consumption ledger tracks the database's block, WAL, and tuple flows as reset-guarded deltas, rolled up daily and weekly. The trend report classifies drift in specific-consumption metrics (blocks per row returned, WAL bytes per row mutated, and six others) against the database's own history, over both a 28-day daily window and an 84-day weekly window.

```sql
SELECT pgfr_analyze.consumption_trend_report();
```

### Capacity planning

```sql
SELECT * FROM pgfr_analyze.capacity_summary('7 days');
SELECT * FROM pgfr_analyze.quarterly_review();
SELECT * FROM pgfr_analyze.capacity_dashboard;
```

## Configuration

Collection cadence is fixed at one minute; tuning happens through config keys in `pgfr_record.config` (safety thresholds, retention days, collector toggles). Profiles are pre-packaged bundles of those keys:

| Profile | Intent |
|---------|--------|
| `default` | General purpose monitoring |
| `production_safe` | Tighter circuit breaker and load shedding, faster section timeouts |
| `development` | Shorter retention (7d snapshots / 3d rollups) |
| `troubleshooting` | Looser thresholds, load shedding off, collect through incidents |
| `minimal_overhead` | Most aggressive skipping, shortest timeouts, shorter retention |

```sql
SELECT * FROM pgfr_record.list_profiles();
SELECT * FROM pgfr_record.explain_profile('production_safe');  -- exact key/value list
SELECT * FROM pgfr_record.apply_profile('production_safe');
```

Collection modes provide coarser manual control by toggling optional collectors:

```sql
SELECT pgfr_record.set_mode('light');     -- progress tracking off
SELECT pgfr_record.set_mode('emergency'); -- minimum collection
SELECT pgfr_record.set_mode('normal');    -- everything back on

SELECT pgfr_record.disable();             -- full stop: unschedule all pg_cron jobs
SELECT pgfr_record.enable();              -- resume
```

## Safety

Flight Recorder includes automatic protections, all recorded in `pgfr_record.collection_stats` when they fire:

| Protection | Description |
|------------|-------------|
| **Circuit breaker** | Skips a collection type when its last 3 runs (within a 15-minute window) averaged over the threshold (default 1s) |
| **Load shedding** | Skips ring sampling when active connections reach the configured share of `max_connections` (default 70%) |
| **Section timeouts** | Per-section timeout inside `snapshot()` (default 250ms) so one slow catalog query can't stall the rest |
| **Job timeouts** | Outer `statement_timeout` on every pg_cron job (500ms to 60s; see the jobs table above) |

## pg_cron run history

pg_cron logs every job execution to `cron.job_run_details` with no built-in purge. pgfr_record schedules 7 jobs, two of them every minute, adding roughly 2,900 rows/day of unbounded growth on top of any other pg_cron jobs you run.

**Recommended: disable `cron.log_run`.** Errors from failed jobs still appear in the Postgres server log (`cron.log_min_messages` defaults to `WARNING`); you lose only the `job_run_details` success rows.

```sql
ALTER SYSTEM SET cron.log_run = off;
-- requires Postgres restart (postmaster context)
```

If you need successful-run history for other pg_cron jobs (as of pg_cron 1.6 there is no per-job logging toggle), schedule a periodic purge instead:

```sql
SELECT cron.schedule(
  'pgfr_purge_cron_log',
  '0 * * * *',
  $$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '1 day'$$
);
```

`pgfr_record.enable()` raises a `WARNING` if `cron.log_run` is left on.

## Export

```bash
# Without compression
pg_dump -d your_database -n pgfr_record --data-only -f pgfr_data.sql

# With compression (PostgreSQL 16+)
pg_dump -d your_database -n pgfr_record --data-only --compress=gzip:9 -f pgfr_data.sql.gz

# With compression (PostgreSQL 15)
pg_dump -d your_database -n pgfr_record --data-only | gzip > pgfr_data.sql.gz
```

## Upgrade

Re-running install scripts is safe: they use `CREATE OR REPLACE` and `IF NOT EXISTS`, updating functions and views while preserving all data.

```bash
psql --single-transaction -f pgfr_record/install.sql
psql --single-transaction -f pgfr_analyze/install.sql
```

## Uninstall

```bash
# Remove everything (unschedules all pgfr_ cron jobs, drops all schemas and data)
psql --single-transaction -f pgfr_record/uninstall.sql

# Remove only reporting functions (keeps core + data)
psql --single-transaction -f pgfr_analyze/uninstall.sql
```

## Testing

```bash
./test.sh           # Test all PostgreSQL versions in parallel (requires Docker)
./test.sh 17        # Test a specific PostgreSQL version (15, 16, 17, or 18)
```

## Reference

See [REFERENCE.md](REFERENCE.md) for the full function reference, table schemas, configuration settings, and detailed documentation.

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE) for attribution.
