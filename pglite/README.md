# pg-flight-recorder PGLite Support

Run pg-flight-recorder analysis functions locally using [PGLite](https://pglite.dev/) without needing a full PostgreSQL server.

## Overview

This allows you to:

- Export flight_recorder data from production (up to ~2.5GB for default retention)
- Import into PGLite running in Node.js
- Run analysis functions locally (report, anomaly_report, what_happened_at, etc.)

## Workflow

### 1. Export Data from Production

On your production database:

```bash
# Prepare data for export (populates relation_names table)
psql -d your_database -f pglite/export.sql

# Export the data
pg_dump -d your_database -n flight_recorder --data-only -f flight_recorder_data.sql

# Or compressed
pg_dump -d your_database -n flight_recorder --data-only | gzip > flight_recorder_data.sql.gz
```

### 2. Set Up PGLite

```javascript
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';

// Create PGLite instance
const db = new PGlite();

// Install analysis-only schema
const installSql = fs.readFileSync('pglite/install.sql', 'utf8');
await db.exec(installSql);

// Import data
const dataSql = fs.readFileSync('flight_recorder_data.sql', 'utf8');
await db.exec(dataSql);
```

### 3. Run Analysis

```javascript
// Anomaly report
const anomalies = await db.query(`
  SELECT * FROM flight_recorder.anomaly_report(
    now() - interval '24 hours',
    now()
  )
`);

// What happened at a specific time
const activity = await db.query(`
  SELECT * FROM flight_recorder.config_at('2024-01-15 14:30:00')
`);

// Table hotspots
const hotspots = await db.query(`
  SELECT * FROM flight_recorder.table_hotspots('24 hours', 10)
`);
```

## Available Functions

The analysis-only schema includes:

| Function | Description |
|----------|-------------|
| `compare(start, end)` | Compare two snapshots |
| `anomaly_report(start, end)` | Detect anomalies in time range |
| `wait_summary(start, end)` | Wait event breakdown |
| `statement_compare(start, end)` | Query performance changes |
| `config_at(timestamp)` | Config at point in time |
| `config_changes(start, end)` | Config change history |
| `table_hotspots(interval, limit)` | Most active tables |
| `unused_indexes(interval, min_size)` | Unused indexes |

## Available Views

| View | Description |
|------|-------------|
| `deltas` | Snapshot-over-snapshot changes |
| `recent_waits` | Wait events from ring buffer |
| `recent_activity` | Session activity |
| `recent_locks` | Lock contention |
| `recent_replication` | Replica status |
| `recent_vacuum_progress` | Vacuum operations |

## Differences from Full Install

The analysis-only schema:

- **No pg_cron dependency** - Collection is disabled
- **Uses relation_names table** - OIDs resolve via lookup table instead of `::regclass`
- **Uses config_snapshots** - Settings retrieved from captured data instead of `pg_settings`
- **No collection functions** - `sample()`, `snapshot()`, `enable()`, `disable()` not included

## File Structure

```
pglite/
├── README.md       # This file
├── install.sql     # Analysis-only schema for PGLite
└── export.sql      # Run on production before pg_dump
```

## Notes

- Ring buffer data (`recent_*` views) shows data from imported ring buffers, but `now()` comparisons may not work as expected since PGLite's `now()` differs from capture time
- For historical analysis, use explicit time ranges: `anomaly_report('2024-01-15 00:00', '2024-01-15 23:59')`
- Archive tables (`*_archive`) contain durable historical data and are more reliable for offline analysis
