# pg-flight-recorder Reference

A PostgreSQL monitoring extension that continuously samples database state for incident analysis and capacity planning.

## Quick Start

```sql
-- Install
\i install.sql

-- Enable collection
SELECT flight_recorder.enable();

-- Check health
SELECT * FROM flight_recorder.health_check();

-- Generate diagnostic report
SELECT flight_recorder.report('1 hour');
```

## Requirements

- PostgreSQL 15, 16, or 17
- `pg_cron` extension
- Superuser privileges for installation
- Optional: `pg_stat_statements` for query analysis

## Architecture

Flight Recorder collects two types of data:

| System | What it captures | Frequency | Retention |
|--------|------------------|-----------|-----------|
| **Sampled Activity** | Wait events, sessions, locks | 3 min | Ring buffer: 6-10h, Archives: 7d |
| **Snapshots** | WAL, checkpoints, I/O, tables, indexes | 5 min | 30 days |

Data flows through ring buffers (hot, UNLOGGED) to archives and aggregates (cold, durable).

## Configuration Profiles

Profiles are pre-configured settings for different environments.

| Profile | Sample Interval | Use Case |
|---------|-----------------|----------|
| `default` | 180s | General purpose monitoring |
| `production_safe` | 300s | Production with maximum safety margins |
| `development` | 180s | Staging and development |
| `troubleshooting` | 60s | Active incident response |
| `minimal_overhead` | 300s | Resource-constrained systems |

```sql
-- List profiles
SELECT * FROM flight_recorder.list_profiles();

-- Preview changes before applying
SELECT * FROM flight_recorder.explain_profile('production_safe');

-- Apply a profile
SELECT * FROM flight_recorder.apply_profile('production_safe');

-- Check current profile
SELECT * FROM flight_recorder.get_current_profile();
```

## Functions

### Analysis

| Function | Purpose |
|----------|---------|
| `report(interval)` | Comprehensive diagnostic report |
| `anomaly_report(start, end)` | Detailed anomaly analysis |
| `wait_summary(start, end)` | Wait event breakdown |
| `statement_compare(start, end)` | Query performance changes |
| `table_hotspots(start, end)` | Tables with high activity |
| `table_compare(start, end)` | Table stats changes |
| `index_efficiency(start, end)` | Index usage analysis |
| `unused_indexes(interval)` | Indexes with no scans |
| `what_happened_at(timestamp)` | Point-in-time analysis |
| `incident_timeline(start, end)` | Event timeline for incidents |

### Anomaly Detection

| Function | Purpose |
|----------|---------|
| `detect_query_storms(interval)` | Find abnormal query patterns |
| `detect_regressions(interval)` | Find performance regressions |
| `blast_radius(queryid)` | Analyze query impact |
| `blast_radius_report(interval)` | Report on high-impact queries |

### Capacity Planning

| Function | Purpose |
|----------|---------|
| `capacity_summary(interval)` | Resource utilization summary |
| `quarterly_review()` | Comprehensive capacity review |
| `dead_tuple_growth_rate(oid, interval)` | Dead tuple accumulation rate |
| `time_to_budget_exhaustion(oid, budget)` | Estimate autovacuum timing |
| `oid_consumption_rate(interval)` | OID usage rate |
| `time_to_oid_exhaustion()` | Estimate OID exhaustion |

### Configuration Analysis

| Function | Purpose |
|----------|---------|
| `config_changes(start, end)` | PostgreSQL config changes |
| `config_at(timestamp)` | Config at a point in time |
| `config_health_check()` | Configuration recommendations |
| `db_role_config_changes(start, end)` | Database/role config changes |
| `db_role_config_summary()` | Current db/role overrides |

### Control

| Function | Purpose |
|----------|---------|
| `enable()` | Start collection jobs |
| `disable()` | Stop collection jobs |
| `health_check()` | System health status |
| `preflight_check()` | Pre-installation validation |
| `set_mode(mode)` | Set collection mode (normal/light/emergency/kill) |
| `get_mode()` | Get current mode |

### Ring Buffer Management

| Function | Purpose |
|----------|---------|
| `ring_buffer_health()` | Ring buffer status |
| `rebuild_ring_buffers(slots)` | Resize ring buffers (clears data) |
| `configure_ring_autovacuum(enabled)` | Toggle autovacuum on ring tables |
| `validate_ring_configuration()` | Check ring buffer config |

### Profile Management

| Function | Purpose |
|----------|---------|
| `list_profiles()` | Available profiles |
| `explain_profile(name)` | Preview profile changes |
| `apply_profile(name)` | Apply profile settings |
| `get_current_profile()` | Current profile match |
| `get_optimization_profiles()` | Ring buffer optimization presets |
| `apply_optimization_profile(name)` | Apply ring buffer optimization |

### Export/Offline Analysis

| Function | Purpose |
|----------|---------|
| `_populate_relation_names()` | Populate OID-to-name lookup table for export |
| `_safe_relname(oid)` | Resolve OID to name using `relation_names` table |
| `_get_setting_from_snapshots(name, default)` | Get setting from captured `config_snapshots` |

## Views

### Real-time (from ring buffers)

| View | Purpose |
|------|---------|
| `recent_waits` | Wait events (last 6-10h) |
| `recent_activity` | Active sessions |
| `recent_locks` | Lock contention |
| `recent_idle_in_transaction` | Idle-in-transaction sessions |
| `recent_vacuum_progress` | Vacuum operations in progress |
| `recent_replication` | Replication status |

### Derived

| View | Purpose |
|------|---------|
| `deltas` | Snapshot-over-snapshot changes |
| `capacity_dashboard` | Resource utilization overview |
| `archiver_status` | WAL archiving status |

## Tables

### Ring Buffers (UNLOGGED, auto-overwrite)

- `samples_ring` - Slot tracker
- `wait_samples_ring` - Wait event samples
- `activity_samples_ring` - Session samples
- `lock_samples_ring` - Lock samples

### Archives (durable, 7-day retention)

- `wait_samples_archive` - Preserved wait samples
- `activity_samples_archive` - Preserved session samples
- `lock_samples_archive` - Preserved lock samples

### Aggregates (durable, 7-day retention)

- `wait_event_aggregates` - Summarized wait events
- `activity_aggregates` - Summarized activity
- `lock_aggregates` - Summarized locks

### Snapshots (durable, 30-day retention)

- `snapshots` - System stats (WAL, checkpoints, I/O)
- `statement_snapshots` - Query stats (from pg_stat_statements)
- `table_snapshots` - Per-table stats (see note on deprecated columns)
- `index_snapshots` - Per-index stats (see note on deprecated columns)
- `config_snapshots` - PostgreSQL configuration
- `db_role_config_snapshots` - Database/role config overrides
- `replication_snapshots` - Replication state
- `vacuum_progress_snapshots` - Vacuum progress

### Internal

- `config` - Flight Recorder configuration
- `collection_stats` - Collection job metrics
- `relation_names` - OID to relation name mappings (for offline analysis)

### Deprecated Columns

The following columns in `table_snapshots` and `index_snapshots` are **deprecated** and will be NULL in new data:

| Table | Deprecated Columns | Use Instead |
|-------|-------------------|-------------|
| `table_snapshots` | `schemaname`, `relname` | `relid::regclass` or `relation_names` lookup |
| `index_snapshots` | `schemaname`, `relname`, `indexrelname` | `relid::regclass`, `indexrelid::regclass` |

This change eliminates joins to `pg_catalog` during collection, avoiding even `AccessShareLock`. Relation names are now derived on-the-fly when queried. Existing data with names is preserved.

## Safety Features

Flight Recorder includes multiple safety mechanisms to prevent impacting production workloads.

### Collection Modes

| Mode | Behavior |
|------|----------|
| `normal` | Full collection |
| `light` | Reduced collection (skips locks, progress) |
| `emergency` | Minimal collection |
| `kill` | All collection disabled |

### Automatic Protections

| Protection | Description |
|------------|-------------|
| **Circuit Breaker** | Auto-disables if collections exceed 1s |
| **Load Shedding** | Skips collection when >70% connections active |
| **Load Throttle** | Skips during high I/O pressure |
| **Adaptive Sampling** | Skips when system is idle |
| **DDL Lock Check** | Avoids collection during schema changes |
| **Replica Lag Check** | Pauses on replicas with high lag |

### Manual Controls

```sql
-- Emergency stop
SELECT flight_recorder.set_mode('kill');

-- Resume normal operation
SELECT flight_recorder.set_mode('normal');

-- Check current mode
SELECT flight_recorder.get_mode();
```

## Key Configuration Settings

Settings are stored in `flight_recorder.config`. Profiles set groups of related settings.

| Setting | Default | Description |
|---------|---------|-------------|
| `sample_interval_seconds` | 180 | Seconds between samples |
| `ring_buffer_slots` | 120 | Number of ring buffer slots (72-2880) |
| `retention_snapshots_days` | 30 | Snapshot retention |
| `retention_samples_days` | 7 | Archive/aggregate retention |
| `circuit_breaker_threshold_ms` | 1000 | Max collection duration |
| `load_shedding_active_pct` | 70 | Connection % threshold |

```sql
-- View all settings
SELECT * FROM flight_recorder.config ORDER BY key;

-- Update a setting
UPDATE flight_recorder.config SET value = '300' WHERE key = 'sample_interval_seconds';
```

## Common Workflows

### Daily Monitoring

```sql
-- Quick health check
SELECT * FROM flight_recorder.health_check();

-- Recent report
SELECT flight_recorder.report('1 hour');
```

### Incident Response

```sql
-- Switch to detailed collection
SELECT * FROM flight_recorder.apply_profile('troubleshooting');

-- Analyze specific time window
SELECT flight_recorder.report(
    '2024-01-15 14:00'::timestamptz,
    '2024-01-15 15:00'::timestamptz
);

-- Point-in-time analysis
SELECT * FROM flight_recorder.what_happened_at('2024-01-15 14:32');

-- Return to normal after incident
SELECT * FROM flight_recorder.apply_profile('default');
```

### Performance Analysis

```sql
-- Find slow queries
SELECT * FROM flight_recorder.detect_regressions('1 day');

-- Find query storms
SELECT * FROM flight_recorder.detect_query_storms('1 hour');

-- Table hotspots
SELECT * FROM flight_recorder.table_hotspots(now() - '1 day', now());

-- Index efficiency
SELECT * FROM flight_recorder.index_efficiency(now() - '1 day', now());
```

### Capacity Planning

```sql
-- Resource summary
SELECT * FROM flight_recorder.capacity_summary('7 days');

-- Full quarterly review
SELECT * FROM flight_recorder.quarterly_review();

-- View capacity dashboard
SELECT * FROM flight_recorder.capacity_dashboard;
```

## Upgrading

```sql
-- From existing installation
\i migrations/upgrade.sql

-- Check version
SELECT value FROM flight_recorder.config WHERE key = 'schema_version';
```

## Uninstalling

```sql
-- Disable jobs first
SELECT flight_recorder.disable();

-- Drop schema
DROP SCHEMA flight_recorder CASCADE;
```

## Offline Analysis (PGLite)

Flight Recorder data can be exported and analyzed locally using [PGLite](https://pglite.dev/) without requiring a PostgreSQL server.

### Export from Production

```bash
# Prepare data (populates relation_names lookup table)
psql -d your_database -f pglite/export.sql

# Export data
pg_dump -d your_database -n flight_recorder --data-only -f flight_recorder_data.sql
```

### Import into PGLite (Node.js)

```javascript
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';

const db = new PGlite();

// Install analysis-only schema
await db.exec(fs.readFileSync('pglite/install.sql', 'utf8'));

// Import data
await db.exec(fs.readFileSync('flight_recorder_data.sql', 'utf8'));

// Run analysis
const result = await db.query(`
  SELECT * FROM flight_recorder.anomaly_report(
    '2024-01-15 00:00'::timestamptz,
    '2024-01-15 23:59'::timestamptz
  )
`);
```

### Available in PGLite

The analysis-only schema includes:

- All data tables (for import)
- Core analysis functions: `compare()`, `anomaly_report()`, `wait_summary()`, `statement_compare()`
- Capacity functions: `table_hotspots()`, `unused_indexes()`
- Configuration functions: `config_at()`, `config_changes()`
- Views: `deltas`, `recent_waits`, `recent_activity`, `recent_locks`

**Not included**: Collection functions (`sample()`, `snapshot()`, `enable()`, `disable()`), pg_cron integration.

See `pglite/README.md` for complete documentation.

## Testing

```bash
# Run tests (requires Docker)
./test.sh

# Test specific PostgreSQL version
./test.sh 17

# Test all versions in parallel
./test.sh parallel
```
