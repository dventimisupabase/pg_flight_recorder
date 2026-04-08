# pgfr_record

Core flight recorder extension for PostgreSQL. Continuously samples database state in the background so you can answer "what was happening in my database?" after the fact.

## What it does

pgfr_record installs a set of tables, views, and pg_cron jobs that continuously capture PostgreSQL system state. It uses UNLOGGED ring buffers for high-frequency sampling of wait events, active sessions, and locks, and durable snapshot tables for periodic capture of WAL activity, checkpoints, I/O, table and index stats, query stats, replication state, and configuration. Data flows from ring buffers into archives and aggregates for longer retention.

## Key features

- **Continuous background sampling** via pg_cron -- no external agents or sidecars
- **Ring buffers** (UNLOGGED) for real-time wait events, active sessions, and lock contention
- **Durable snapshots** every minute: WAL, checkpoints, I/O, tables, indexes, statements, replication, configuration
- **Aggregates and archives** for longer retention (7 days for archives, 30 days for snapshots)
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
| `pgfr_record.recent_waits`               | Wait events from ring buffer     |
| `pgfr_record.recent_activity`            | Active sessions from ring buffer |
| `pgfr_record.recent_locks`               | Lock contention from ring buffer |
| `pgfr_record.recent_idle_in_transaction` | Idle-in-transaction sessions     |
| `pgfr_record.recent_replication`         | Replication status               |
| `pgfr_record.recent_vacuum_progress`     | Vacuum operations in progress    |
| `pgfr_record.archiver_status`            | WAL archiving status             |

## Key functions

| Function                        | Description                   |
|---------------------------------|-------------------------------|
| `pgfr_record.enable()`                 | Start collection jobs         |
| `pgfr_record.disable()`                | Stop collection jobs          |
| `pgfr_record.health_check()`           | System health status          |
| `pgfr_record.set_mode(mode)`           | Set collection mode           |
| `pgfr_record.apply_profile(name)`      | Apply a configuration profile |
| `pgfr_record.list_profiles()`          | List available profiles       |
| `pgfr_record.ring_buffer_health()`     | Ring buffer status            |
| `pgfr_record.cleanup()`                | Manual retention cleanup      |

## Profiles

| Profile            | Sample Interval | Use Case                               |
|--------------------|-----------------|----------------------------------------|
| `default`          | 60s             | General purpose monitoring             |
| `production_safe`  | 300s            | Production with maximum safety margins |
| `development`      | 60s             | Staging and development                |
| `troubleshooting`  | 60s             | Active incident response               |
| `minimal_overhead` | 300s            | Resource-constrained systems           |

## Related extensions

- [pgfr_analyze](https://database.dev/dventimi/pgfr_analyze) -- reporting, anomaly detection, time-travel forensics

See the [top-level README](https://github.com/dventimisupabase/pg-flight-recorder/blob/main/README.md) and [REFERENCE.md](https://github.com/dventimisupabase/pg-flight-recorder/blob/main/REFERENCE.md) for full documentation.
