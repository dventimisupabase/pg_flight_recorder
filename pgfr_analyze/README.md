# pgfr_analyze

Reporting and analysis extension for [pgfr_record](https://database.dev/dventimi/pgfr_record). Turns raw flight recorder data into anomaly reports, incident forensics, and capacity planning.

## What it does

pgfr_analyze reads the snapshot and ring buffer data collected by pgfr_record and provides functions for anomaly detection, performance regression analysis, time-travel forensics, blast radius analysis, capacity planning, and configuration change tracking. It never writes to the core schema -- it only reads and computes.

## Key features

- **Anomaly detection**: checkpoint anomalies, buffer pressure, temp file spills, lock contention, XID wraparound risk
- **Query storm and regression detection**: find abnormal query patterns and performance regressions with severity classification
- **Time-travel forensics**: `what_happened_at()` for point-in-time analysis, `incident_timeline()` for event reconstruction
- **Blast radius analysis**: measure the impact of high-cost queries on system resources
- **Capacity planning**: `capacity_summary()`, `quarterly_review()`, and the `capacity_dashboard` view
- **Configuration tracking**: detect PostgreSQL config changes, view config at a point in time, health check recommendations
- **Comprehensive reporting**: `report()` for full diagnostics, `summary_report()`, `performance_report()`

## Requirements

- [pgfr_record](https://database.dev/dventimi/pgfr_record) must be installed first
- Optional: `pg_stat_statements` for query-level analysis

## Install

```sql
-- Install core first if not already installed
\i pgfr_record/install.sql
SELECT pgfr_record.enable();

-- Then install analyze
\i pgfr_analyze/install.sql
```

## Quick start

```sql
-- Compare two snapshots
SELECT * FROM pgfr_analyze.compare(now() - '1 hour', now());

-- Wait event summary over a time range
SELECT * FROM pgfr_analyze.wait_summary(now() - '1 hour', now());

-- Generate a diagnostic report for the last hour
SELECT pgfr_analyze.report('1 hour');

-- Anomaly report over a time range
SELECT * FROM pgfr_analyze.anomaly_report(now() - '1 hour', now());

-- What was happening at a specific time?
SELECT * FROM pgfr_analyze.what_happened_at('2024-01-15 14:32');

-- Reconstruct an incident timeline
SELECT * FROM pgfr_analyze.incident_timeline(
    '2024-01-15 14:00'::timestamptz,
    '2024-01-15 15:00'::timestamptz
);

-- Detect performance regressions
SELECT * FROM pgfr_analyze.detect_regressions('1 day');

-- Detect query storms
SELECT * FROM pgfr_analyze.detect_query_storms('1 hour');

-- Capacity summary
SELECT * FROM pgfr_analyze.capacity_summary('7 days');
```

## Functions

### Comparison and analysis

| Function                                         | Description                                |
|--------------------------------------------------|--------------------------------------------|
| `compare(start, end)`                            | Compare two snapshots side-by-side         |
| `wait_summary(start, end)`                       | Wait event breakdown over a time range     |
| `statement_compare(start, end)`                  | Query performance changes between points   |
| `activity_at(timestamp)`                         | Activity snapshot closest to a timestamp   |
| `recent_waits_current()`                         | Current wait event data from ring buffer   |
| `recent_activity_current()`                      | Current activity data from ring buffer     |
| `recent_locks_current()`                         | Current lock data from ring buffer         |

### Reporting

| Function                         | Description                      |
|----------------------------------|----------------------------------|
| `report(interval)`               | Comprehensive diagnostic report  |
| `report(start, end)`             | Report for a specific time range |
| `summary_report(start, end)`     | Summary statistics               |
| `performance_report(start, end)` | Performance-focused report       |
| `anomaly_report(start, end)`     | Detailed anomaly analysis        |
| `check_alerts()`                 | Check active alert conditions    |

### Forensics

| Function                        | Description                        |
|---------------------------------|------------------------------------|
| `what_happened_at(timestamp)`   | Point-in-time analysis             |
| `incident_timeline(start, end)` | Reconstruct event timeline         |
| `blast_radius(queryid)`         | Measure impact of a specific query |
| `blast_radius_report(interval)` | Report on high-impact queries      |

### Performance analysis

| Function                           | Description                          |
|------------------------------------|--------------------------------------|
| `detect_query_storms(interval)`    | Find abnormal query patterns         |
| `detect_regressions(interval)`     | Find performance regressions         |
| `table_hotspots(start, end)`       | Tables with high activity            |
| `table_compare(start, end)`        | Table stats changes over time        |
| `index_efficiency(start, end)`     | Index usage analysis                 |
| `unused_indexes(interval)`         | Indexes with no scans                |

### Capacity planning

| Function                           | Description                          |
|------------------------------------|--------------------------------------|
| `capacity_summary(interval)`       | Resource utilization summary         |
| `capacity_report(interval)`        | Text capacity report                 |
| `quarterly_review()`               | Comprehensive capacity review        |
| `capacity_dashboard` (view)        | Resource utilization overview        |

### Configuration tracking

| Function                             | Description                   |
|--------------------------------------|-------------------------------|
| `config_changes(start, end)`         | PostgreSQL config changes     |
| `config_at(timestamp)`               | Config at a point in time     |
| `config_health_check()`              | Configuration recommendations |
| `db_role_config_changes(start, end)` | Database/role config changes  |
| `db_role_config_summary()`           | Current db/role overrides     |

### Pre-flight

| Function                           | Description                          |
|------------------------------------|--------------------------------------|
| `preflight_check()`                | Pre-installation validation          |
| `preflight_check_with_summary()`   | Validation with text summary         |

## Related extensions

- [pgfr_record](https://database.dev/dventimi/pgfr_record) -- core snapshot collection (required)

See the [top-level README](https://github.com/dventimisupabase/pg-flight-recorder/blob/main/README.md) and [REFERENCE.md](https://github.com/dventimisupabase/pg-flight-recorder/blob/main/REFERENCE.md) for full documentation.
