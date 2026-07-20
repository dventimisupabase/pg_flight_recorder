# pgfr_record

Core flight recorder extension for PostgreSQL. Continuously samples database state in the background so you can answer "what was happening in my database?" after the fact.

## What it does

pgfr_record installs a set of tables, views, and pg_cron jobs that continuously capture PostgreSQL system state. It uses UNLOGGED ring buffers for high-frequency sampling of wait events, active sessions, and locks, and durable snapshot tables for periodic capture of WAL activity, checkpoints, I/O, table and index stats, query stats, replication state, and configuration. Ring buffers rotate out via TRUNCATE on a fixed schedule, rolling up wait/lock/activity data into durable summary tables just before each rotation for trend visibility beyond the ring's window. Snapshot tables carry their own long-term retention via daily partition drop.

## Key features

- **Continuous background sampling** via pg_cron -- no external agents or sidecars
- **Ring buffers** (UNLOGGED) for real-time wait events, active sessions, and lock contention -- TRUNCATE-rotated on a fixed schedule (default 2h), rolling up into durable wait/lock/activity rollup tables just before each rotation
- **Durable snapshots** every minute: WAL, checkpoints, I/O, tables, indexes, statements, replication, configuration
- **xmin horizon attribution**: captures who is pinning the xmin horizon (long-running txns, stale replication slots, hot-standby-feedback, prepared xacts) so wraparound forensics isn't reduced to live-querying four catalogs after the offender has disconnected
- **Partition-based retention** for snapshot tables (default 30 days), enforced via partition drop rather than DELETE
- **Safety mechanisms**: circuit breaker, load shedding
- **Collection modes**: normal, light, emergency, kill
- **Configurable profiles**: default, production_safe, development, troubleshooting, minimal_overhead
- **Delta views**: snapshot-over-snapshot changes for trend analysis

## Requirements

- PostgreSQL 15, 16, or 17
- `pg_cron` extension
- Superuser privileges for installation
- Optional: `pg_stat_statements` for query-level analysis

## Install

```sql
\i pgfr_record/install.sql
SELECT pgfr_record.enable();
```

Or from the command line:

```bash
psql --single-transaction -f pgfr_record/install.sql
psql -c "SELECT pgfr_record.enable();"
```

## Quick start

```sql
-- Check health
SELECT * FROM pgfr_record.health_check();

-- View recent wait events
SELECT * FROM pgfr_record.recent_waits;

-- View recent active sessions
SELECT * FROM pgfr_record.recent_activity;

-- View recent lock contention
SELECT * FROM pgfr_record.recent_locks;

-- Snapshot-over-snapshot deltas
SELECT * FROM pgfr_record.deltas;
```

## Key views

| View                              | Description                      |
|-----------------------------------|----------------------------------|
| `pgfr_record.deltas`                     | Snapshot-over-snapshot changes   |
| `pgfr_record.recent_waits`               | Wait events from the v2 ring     |
| `pgfr_record.recent_activity`            | Active sessions from the v2 ring |
| `pgfr_record.recent_locks`               | Lock contention from the v2 ring |
| `pgfr_record.recent_idle_in_transaction` | Idle-in-transaction sessions     |
| `pgfr_record.recent_replication`         | Replication status               |
| `pgfr_record.recent_vacuum_progress`     | Vacuum operations in progress    |
| `pgfr_record.archiver_status`            | WAL archiving status             |
| `pgfr_record.consumption_flows`          | Reset-guarded block/WAL/tuple flow rates and efficiency ratios |
| `pgfr_record.consumption_deltas`         | Reset-guarded per-tick component deltas backing `consumption_flows` and the daily rollup |

## Consumption ledger

`pgfr_record.consumption_snapshots_v2` records the database's cumulative block,
WAL, and tuple activity counters once per snapshot tick (piggybacked on the
existing per-minute snapshot trigger -- no extra pg_cron job). `consumption_flows`
derives per-second flow rates and efficiency ratios from consecutive rows: how
much work the database is doing, measured in blocks moved and WAL bytes
generated rather than milliseconds, so the numbers stay comparable across
different hardware.

### Reset handling

Flows and ratios are reset-guarded via `pgfr_record._reset_guarded_delta()`, a
generic primitive: an interval is discarded (NULL) if its source counters
regressed or their `pg_stat_*` view was reset between ticks. Guarding is
per-source, not per-row -- a `pg_stat_reset()` invalidates only the
`pg_stat_database`-scoped flows (rows returned/mutated, transactions, cache
hit fraction) for that interval, and a `pg_stat_reset_shared('wal')`
invalidates only the `pg_stat_wal`-scoped ones (WAL record/FPI decomposition).
`wal_bytes_per_s` is the exception: it's derived from `pg_current_wal_lsn()`
directly, which is monotonic on a primary regardless of any stats reset, and
is treated as the ledger of record for WAL volume. `pg_stat_wal`'s own
`wal_bytes` counter is advisory decomposition only.

### Scope and caveats

- **Primary only.** The collector no-ops under `pg_is_in_recovery()`: several
  source views (`pg_current_wal_lsn()`, `pg_stat_checkpointer`) are absent,
  zero, or misleading on a hot standby. A gap in `consumption_snapshots_v2`
  during a known recovery window is expected, not a bug.
- **Cluster vs. database scope.** `tup_*`, `xact_*`, `blks_*`, `temp_*`, and
  `db_*` columns are scoped to `current_database()`; WAL, I/O-by-agent, and
  checkpointer/bgwriter columns are cluster-wide. On single-database
  deployments this distinction is cosmetic but the schema carries it honestly.
- **`track_io_timing`.** `blk_read_time_ms` / `blk_write_time_ms` are `0` (not
  NULL) for the entire history when `track_io_timing` is off -- treat a
  persistent `0` there as "unknown", not "instant". Recommended on for most
  systems; check the overhead first with `pg_test_timing`.
- **No "physical" I/O, on purpose.** `os_read_blocks_per_s` / `os_write_blocks_per_s`
  count block read/write requests Postgres issues *to the OS* (buffer-pool
  misses) -- not confirmed disk I/O. Postgres has no visibility past that
  boundary: the OS page cache may satisfy an "OS read" without ever touching
  physical storage, and Postgres can't tell which happened. True disk-level
  I/O requires OS/platform metrics (`iostat`, cloud provider disk metrics)
  from outside this database. `block_demand_per_s` (buffer-pool hits + misses)
  has the same property in reverse: it's everything the executor asked the
  buffer pool for, regardless of how each access was satisfied.
- **No CPU.** Core Postgres exposes wall-clock, not cycles; CPU-seconds would
  have to join in from outside the database. Out of scope here.
- **No per-statement attribution.** This is a cluster/database-level ledger;
  `pg_stat_statements`-based drill-down is a separate concern.
- **`recorder_overhead_fraction`.** A footnote-grade self-accounting figure in
  `consumption_flows`: the recorder's own block footprint
  (`pg_statio_user_tables` for the `pgfr_record` schema) as a fraction of the
  ledger's total block demand for that interval.

### Daily rollups

`consumption_snapshots_v2` retains 30 days; trend analysis over longer windows
needs something that survives past that. `pgfr_record.consumption_daily_rollups`
is a daily-grain durable rollup -- one row per calendar day per `datname` --
populated by `_rollup_consumption_daily()` from the existing daily `pgfr_cleanup`
cron job (no separate schedule). It stores summed numerator/denominator
components, not pre-computed ratios, matching this schema's Σnum/Σden rollup
convention: ratios are reconstructed from sums, never averaged from
finer-grained ratios.

Unlike every other durable table in this schema, it's deliberately **not**
partitioned and has **no retention/cleanup**: at one row per day it stays tiny
indefinitely (a decade is ~3,650 rows), so the bloat problem partition-drop
retention exists to solve can't occur here.

`consumption_deltas` -- the reset-guarded per-tick component view that used to
be an inline part of `consumption_flows` -- is now its own view, shared by both
`consumption_flows` (live per-tick ratios) and the daily rollup (`SUM()` across
a day; NULLs from a reset-invalidated tick are skipped by `SUM()` automatically,
so a mid-day `pg_stat_reset()` excludes that tick from the affected sums rather
than corrupting them).

## Ring rollups

Just before `rotate_ring()` truncates a ring buffer slot, that slot's wait/lock/activity
data is rolled up into three durable tables for trend visibility beyond the ring's 2h
window -- no separate cron job, no persisted flush watermark, just an in-place rollup at
the exact moment the data would otherwise be destroyed.

- **`wait_event_rollups_archive_v2`**: one row per (backend_type, wait_event_type,
  wait_event) per rotation window -- sample counts, waiter counts, percentage of samples.
- **`lock_rollups_archive_v2`**: one row per (lock_type, locked relation) per rotation
  window -- occurrence counts and blocked-duration stats.
- **`activity_rollups_archive_v2`**: one row per (backend_type, state, duration_bucket)
  per rotation window -- how long sessions had been running their current query when
  sampled, bucketed rather than grouped by raw query text (that's what
  `pgfr_record.statement_snapshots_v2`'s real `queryid`-based stats are for).

All three are daily RANGE-partitioned by `sample_ts` and named `*_archive_v2` so they
fall under `_partition_inventory()`'s existing archive-tier retention
(`retention_archive_days`, default 7 days) with no separate config key.

## Key functions

| Function                        | Description                   |
|---------------------------------|-------------------------------|
| `pgfr_record.enable()`                 | Start collection jobs         |
| `pgfr_record.disable()`                | Stop collection jobs          |
| `pgfr_record.health_check()`           | System health status          |
| `pgfr_record.set_mode(mode)`           | Set collection mode           |
| `pgfr_record.apply_profile(name)`      | Apply a configuration profile |
| `pgfr_record.list_profiles()`          | List available profiles       |
| `pgfr_record.sample_ring()`            | One-shot v2 ring sample       |
| `pgfr_record.cleanup()`                | Manual retention cleanup      |

## Profiles

| Profile            | Sample Interval | Use Case                               |
|--------------------|-----------------|----------------------------------------|
| `default`          | 60s             | General purpose monitoring             |
| `production_safe`  | 300s            | Production with maximum safety margins |
| `development`      | 60s             | Staging and development                |
| `troubleshooting`  | 60s             | Active incident response               |
| `minimal_overhead` | 300s            | Resource-constrained systems           |

## pg_cron run history

Every scheduled job writes a row to `cron.job_run_details`, and pg_cron has no built-in purge. pgfr_record schedules ~10 jobs (four fire every minute), so at default cadence expect ~5,000 rows/day growing forever on top of any other pg_cron jobs.

`pgfr_record.enable()` raises a `WARNING` when it detects `cron.log_run` is on. To silence it, pick one:

```sql
-- Preferred: disable run logging entirely (errors still hit the server log).
ALTER SYSTEM SET cron.log_run = off;
-- requires a Postgres restart (postmaster context)

-- Or, if you need run history for other pg_cron jobs, purge periodically:
SELECT cron.schedule(
  'pgfr_purge_cron_log',
  '0 * * * *',
  $$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '1 day'$$
);
```

See the [top-level README](https://github.com/dventimisupabase/pg_flight_recorder/blob/main/README.md#pg_cron-run-history) for the full rationale.

## Related extensions

- [pgfr_analyze](https://database.dev/dventimi/pgfr_analyze) -- reporting, anomaly detection, time-travel forensics

See the [top-level README](https://github.com/dventimisupabase/pg_flight_recorder/blob/main/README.md) and [REFERENCE.md](https://github.com/dventimisupabase/pg_flight_recorder/blob/main/REFERENCE.md) for full documentation.
