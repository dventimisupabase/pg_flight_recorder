# pg-flight-recorder

[![GitHub release](https://img.shields.io/github/v/release/dventimisupabase/pg-flight-recorder)](https://github.com/dventimisupabase/pg-flight-recorder/releases/latest)
[![Test Suite](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/test.yml/badge.svg)](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/test.yml)
[![Lint](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/lint.yml/badge.svg)](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/lint.yml)

Server-side flight recorder for PostgreSQL. Answers "what was happening in my database?"

**[View the project website](https://dventimisupabase.github.io/pg-flight-recorder/)**

pg-flight-recorder continuously samples PostgreSQL system state in the background via pg_cron -- no external agents, sidecars, or polling required. It captures wait events, active sessions, locks, WAL activity, checkpoints, I/O, table and index stats, query performance, replication state, and configuration changes. When something goes wrong, the data is already there.

## Architecture

Flight Recorder collects two types of data:

| System               | What it captures                       | Frequency | Retention                         |
|----------------------|----------------------------------------|-----------|-----------------------------------|
| **Sampled Activity** | Wait events, sessions, locks           | 1 min     | Ring buffer: 2h, Archives: 7d     |
| **Snapshots**        | WAL, checkpoints, I/O, tables, indexes | 1 min     | 30 days                           |

Data flows through UNLOGGED ring buffers (hot, low-overhead) into durable archives and aggregates (cold, long-retention). Safety mechanisms -- circuit breaker, load shedding, per-section timeouts, and pg_cron job timeouts -- prevent the recorder from impacting production workloads.

## Extensions

Two extensions, each published as a separate [dbdev](https://database.dev) package:

| Extension                                                  | Schema         | Purpose                                                  | README                                   |
|------------------------------------------------------------|----------------|----------------------------------------------------------|------------------------------------------|
| [pgfr_record](https://database.dev/dventimi/pgfr_record)   | `pgfr_record`  | Core: tables, collection, scheduling, ring buffers       | [pgfr_record/README.md](pgfr_record/README.md)   |
| [pgfr_analyze](https://database.dev/dventimi/pgfr_analyze) | `pgfr_analyze` | Optional: reporting, anomaly detection, time travel      | [pgfr_analyze/README.md](pgfr_analyze/README.md) |

## Requirements

- PostgreSQL 15, 16, or 17
- `pg_cron` extension
- Superuser privileges for installation
- Optional: `pg_stat_statements` for query-level analysis

## Quick start

Download from [GitHub Releases](https://github.com/dventimisupabase/pg-flight-recorder/releases/latest) or clone the repo, then:

```bash
# Install core + optional analysis extension
psql --single-transaction -f pgfr_record/install.sql
psql --single-transaction -f pgfr_analyze/install.sql
```

```sql
-- Enable collection
SELECT pgfr_record.enable();

-- Check health
SELECT * FROM pgfr_record.health_check();

-- Generate a diagnostic report
SELECT pgfr_analyze.report('1 hour');
```

## Common workflows

### Daily monitoring

```sql
SELECT * FROM pgfr_record.health_check();
SELECT pgfr_analyze.report('1 hour');
```

### Incident response

```sql
-- Switch to high-frequency collection
SELECT * FROM pgfr_record.apply_profile('troubleshooting');

-- What was happening at a specific time?
SELECT * FROM pgfr_analyze.what_happened_at('2024-01-15 14:32');

-- Reconstruct an incident timeline
SELECT * FROM pgfr_analyze.incident_timeline(
    '2024-01-15 14:00'::timestamptz,
    '2024-01-15 15:00'::timestamptz
);

-- Return to normal after incident
SELECT * FROM pgfr_record.apply_profile('default');
```

### Performance analysis

```sql
-- Find performance regressions
SELECT * FROM pgfr_analyze.detect_regressions('1 day');

-- Find query storms
SELECT * FROM pgfr_analyze.detect_query_storms('1 hour');

-- Table hotspots
SELECT * FROM pgfr_analyze.table_hotspots(now() - '1 day', now());

-- Unused indexes
SELECT * FROM pgfr_analyze.unused_indexes('7 days');
```

### Capacity planning

```sql
SELECT * FROM pgfr_analyze.capacity_summary('7 days');
SELECT * FROM pgfr_analyze.quarterly_review();
SELECT * FROM pgfr_analyze.capacity_dashboard;
```

## Configuration profiles

Profiles are pre-configured settings for different environments:

| Profile            | Sample Interval | Use Case                               |
|--------------------|-----------------|----------------------------------------|
| `default`          | 60s             | General purpose monitoring             |
| `production_safe`  | 300s            | Production with maximum safety margins |
| `development`      | 60s             | Staging and development                |
| `troubleshooting`  | 60s             | Active incident response               |
| `minimal_overhead` | 300s            | Resource-constrained systems           |

```sql
SELECT * FROM pgfr_record.list_profiles();
SELECT * FROM pgfr_record.explain_profile('production_safe');
SELECT * FROM pgfr_record.apply_profile('production_safe');
```

## Safety

Flight Recorder includes automatic protections:

| Protection             | Description                                           |
|------------------------|-------------------------------------------------------|
| **Circuit Breaker**    | Skips collection if recent runs averaged > 1s         |
| **Load Shedding**      | Skips collection when > 70% connections active        |
| **Section Timeouts**   | Per-query timeout (250ms) prevents catalog lock hangs |
| **Job Timeouts**       | Outer statement_timeout on all pg_cron jobs (5-60s)   |

Collection modes provide manual control: `normal`, `light`, `emergency`, `kill`.

```sql
-- Emergency stop
SELECT pgfr_record.set_mode('kill');

-- Resume
SELECT pgfr_record.set_mode('normal');
```

## Export

With default retention: ~2.5GB uncompressed, ~150MB compressed.

```bash
# Without compression
pg_dump -d your_database -n pgfr_record --data-only -f pgfr_data.sql

# With compression (PostgreSQL 16+)
pg_dump -d your_database -n pgfr_record --data-only --compress=gzip:9 -f pgfr_data.sql.gz

# With compression (PostgreSQL 15)
pg_dump -d your_database -n pgfr_record --data-only | gzip > pgfr_data.sql.gz
```

## Upgrade

Re-running install scripts is safe -- they use `CREATE OR REPLACE` and `IF NOT EXISTS`, updating functions and views while preserving all data.

```bash
psql --single-transaction -f pgfr_record/install.sql
psql --single-transaction -f pgfr_analyze/install.sql
```

## Uninstall

```bash
# Remove everything (stops jobs, drops all schemas and data)
psql --single-transaction -f pgfr_record/uninstall.sql

# Remove only reporting functions (keeps core + data)
psql --single-transaction -f pgfr_analyze/uninstall.sql
```

## Testing

```bash
./test.sh           # Run tests (requires Docker)
./test.sh 17        # Test specific PostgreSQL version
./test.sh parallel  # Test all versions in parallel
```

## Reference

See [REFERENCE.md](REFERENCE.md) for the full function reference, table schemas, configuration settings, and detailed documentation.
