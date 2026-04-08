# pg-flight-recorder Reference

[![GitHub release](https://img.shields.io/github/v/release/dventimisupabase/pg-flight-recorder)](https://github.com/dventimisupabase/pg-flight-recorder/releases/latest)
[![Test Suite](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/test.yml/badge.svg)](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/test.yml)
[![Lint](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/lint.yml/badge.svg)](https://github.com/dventimisupabase/pg-flight-recorder/actions/workflows/lint.yml)

Complete reference for [pg-flight-recorder](README.md). For installation and getting started, see the [README](README.md). For per-extension overviews, see [pgfr_record](pgfr_record/README.md) and [pgfr_analyze](pgfr_analyze/README.md).

## Functions: pgfr_record (core)

### Control

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_record.enable()` | `text` | Start collection jobs via pg_cron |
| `pgfr_record.disable()` | `text` | Stop collection jobs |
| `pgfr_record.health_check()` | `record` | System health status with diagnostics |
| `pgfr_record.set_mode(mode text)` | `text` | Set collection mode: `normal`, `light`, `emergency`, `kill` |
| `pgfr_record.get_mode()` | `record` | Get current collection mode |
| `pgfr_record.validate_config()` | `record` | Validate all configuration settings |
| `pgfr_record.config_recommendations()` | `record` | Get configuration recommendations based on system state |

### Collection

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_record.snapshot()` | `timestamptz` | Durable snapshot: WAL, checkpoints, I/O, tables, indexes, statements, replication, config |
| `pgfr_record.sample()` | `timestamptz` | Sampled activity: wait events, active sessions, locks into ring buffers |
| `pgfr_record.flush_ring_to_aggregates()` | `void` | Flush ring buffer data to durable aggregate tables (every 5 min) |
| `pgfr_record.archive_ring_samples()` | `void` | Archive raw ring buffer samples to durable archive tables (every 15 min) |
| `pgfr_record.cleanup()` | `record` | Remove expired data based on retention settings |
| `pgfr_record.cleanup_aggregates()` | `void` | Remove old aggregate and archive data |

### Profile management

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_record.list_profiles()` | `record` | List available configuration profiles |
| `pgfr_record.explain_profile(name text)` | `record` | Preview what a profile would change |
| `pgfr_record.apply_profile(name text)` | `record` | Apply a configuration profile |
| `pgfr_record.get_current_profile()` | `record` | Identify which profile matches current settings |
| `pgfr_record.get_optimization_profiles()` | `record` | List ring buffer optimization presets |
| `pgfr_record.apply_optimization_profile(name text)` | `record` | Apply a ring buffer optimization preset |

### Ring buffer management

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_record.ring_buffer_health()` | `record` | Ring buffer fill status and diagnostics |
| `pgfr_record.rebuild_ring_buffers(slots int)` | `text` | Resize ring buffers (72-2880 slots). **Clears ring data**; archives and aggregates preserved |
| `pgfr_record.configure_ring_autovacuum(enabled bool)` | `text` | Toggle autovacuum on ring buffer tables |
| `pgfr_record.validate_ring_configuration()` | `record` | Validate ring buffer retention, batching, CPU, and memory |

### Export

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_record.export_for_upgrade()` | `record` | Prepare data for export with OID-to-name resolution |
| `pgfr_record._populate_relation_names()` | `int` | Populate OID-to-name lookup table for offline analysis |
| `pgfr_record._safe_relname(oid)` | `text` | Resolve OID to schema-qualified name using `relation_names` |
| `pgfr_record._get_setting_from_snapshots(name text, default_val text)` | `text` | Get a setting value from captured `config_snapshots` |

## Functions: pgfr_analyze

### Comparison and analysis

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_analyze.compare(start timestamptz, end timestamptz)` | `record` | Compare two snapshots side-by-side with deltas |
| `pgfr_analyze.wait_summary(start timestamptz, end timestamptz)` | `record` | Wait event breakdown over a time range |
| `pgfr_analyze.statement_compare(start timestamptz, end timestamptz, min_delta_ms float8, limit int)` | `record` | Query performance changes between two points |
| `pgfr_analyze.activity_at(ts timestamptz)` | `record` | Activity snapshot closest to a timestamp |
| `pgfr_analyze.recent_waits_current()` | `record` | Current wait event data from ring buffer |
| `pgfr_analyze.recent_activity_current()` | `record` | Current activity data from ring buffer |
| `pgfr_analyze.recent_locks_current()` | `record` | Current lock data from ring buffer |

### Reporting

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_analyze.report(interval)` | `text` | Comprehensive diagnostic report for a time window |
| `pgfr_analyze.report(start timestamptz, end timestamptz)` | `text` | Diagnostic report for a specific time range |
| `pgfr_analyze.summary_report(start timestamptz, end timestamptz)` | `record` | Summary statistics |
| `pgfr_analyze.performance_report(start timestamptz, end timestamptz)` | `record` | Performance-focused report |
| `pgfr_analyze.anomaly_report(start timestamptz, end timestamptz)` | `record` | Anomaly analysis: checkpoints, buffer pressure, temp spills, locks, XID risk |
| `pgfr_analyze.check_alerts()` | `record` | Check active alert conditions |

### Forensics

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_analyze.what_happened_at(ts timestamptz)` | `record` | Point-in-time analysis: snapshots, waits, activity, locks around a timestamp |
| `pgfr_analyze.incident_timeline(start timestamptz, end timestamptz)` | `record` | Reconstructed event timeline for an incident window |
| `pgfr_analyze.blast_radius(queryid bigint)` | `record` | Impact analysis for a specific query: I/O, CPU, lock, temp file effects |
| `pgfr_analyze.blast_radius_report(interval)` | `text` | Text report on high-impact queries |

### Performance analysis

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_analyze.detect_query_storms(interval, threshold numeric)` | `record` | Find queries with abnormal execution counts. Classifies: RETRY_STORM, CACHE_MISS, SPIKE, NORMAL. Severity: LOW, MEDIUM, HIGH, CRITICAL |
| `pgfr_analyze.detect_regressions(interval, threshold numeric)` | `record` | Find performance regressions via buffer metrics or timing. Severity: LOW (<200%), MEDIUM (<500%), HIGH (<1000%), CRITICAL (>1000%) |
| `pgfr_analyze.table_hotspots(start timestamptz, end timestamptz)` | `record` | Tables with highest activity (scans, modifications, dead tuples) |
| `pgfr_analyze.table_compare(start timestamptz, end timestamptz, top_n int)` | `record` | Table stats changes over a time range |
| `pgfr_analyze.index_efficiency(start timestamptz, end timestamptz, top_n int)` | `record` | Index usage analysis: scan counts, tuple fetches, sizes |
| `pgfr_analyze.unused_indexes(interval)` | `record` | Indexes with zero scans over a time window |
| `pgfr_analyze.modification_rate(relid oid, window interval)` | `numeric` | Row modification rate (modifications/second) for a table |
| `pgfr_analyze.hot_update_ratio(relid oid)` | `numeric` | HOT update percentage (0-100) from latest snapshot |

### Capacity planning

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_analyze.capacity_summary(interval)` | `record` | Resource utilization summary: connections, disk, WAL, transactions |
| `pgfr_analyze.capacity_report(interval)` | `text` | Text capacity report |
| `pgfr_analyze.quarterly_review()` | `record` | Comprehensive capacity review with growth trends |
| `pgfr_analyze.quarterly_review_with_summary()` | `record` | Quarterly review with text summary |

### Configuration tracking

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_analyze.config_changes(start timestamptz, end timestamptz)` | `record` | PostgreSQL configuration changes between two points |
| `pgfr_analyze.config_at(ts timestamptz, name text)` | `record` | Configuration state at a point in time |
| `pgfr_analyze.config_health_check()` | `record` | Configuration recommendations based on current settings |
| `pgfr_analyze.db_role_config_at(ts timestamptz, db text, role text, param text)` | `record` | Database/role config at a point in time |
| `pgfr_analyze.db_role_config_changes(start timestamptz, end timestamptz)` | `record` | Database/role configuration changes |
| `pgfr_analyze.db_role_config_summary()` | `record` | Current database/role overrides |

### Pre-flight

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_analyze.preflight_check()` | `record` | Pre-installation validation checks |
| `pgfr_analyze.preflight_check_with_summary()` | `record` | Validation with text summary |

## Views

### pgfr_record (core)

| View | Source | Description |
|------|--------|-------------|
| `pgfr_record.deltas` | Snapshots | Snapshot-over-snapshot changes for all metrics |
| `pgfr_record.recent_waits` | Ring buffer + archives | Wait events (last 6-10h from ring, 7d from archives) |
| `pgfr_record.recent_activity` | Ring buffer + archives | Active sessions with wait events and query previews |
| `pgfr_record.recent_locks` | Ring buffer + archives | Lock contention: blocked/blocking pairs |
| `pgfr_record.recent_idle_in_transaction` | Ring buffer + archives | Sessions idle in transaction with duration |
| `pgfr_record.recent_replication` | Snapshots | Replication status: lag, LSN positions |
| `pgfr_record.recent_vacuum_progress` | Snapshots | Vacuum operations in progress with % scanned/vacuumed |
| `pgfr_record.archiver_status` | Snapshots | WAL archiver status with delta calculations |

### pgfr_analyze

| View | Source | Description |
|------|--------|-------------|
| `pgfr_analyze.capacity_dashboard` | Snapshots | Resource utilization overview: connections, disk, WAL, transactions |

## Tables

### Ring buffers (UNLOGGED, auto-overwrite)

**`pgfr_record.samples_ring`** -- Slot tracker (configurable slots, default 120, range 72-2880)

| Column | Type | Description |
|--------|------|-------------|
| `slot_id` | int | Ring buffer slot index |
| `captured_at` | timestamptz | When this slot was last written |
| `epoch_seconds` | bigint | Epoch timestamp for fast comparisons |

**`pgfr_record.wait_samples_ring`** -- Wait event samples (slots x 100 rows)

| Column | Type | Description |
|--------|------|-------------|
| `slot_id` | int | Ring buffer slot index |
| `row_num` | int | Row within slot (1-100) |
| `backend_type` | text | Backend type (client backend, autovacuum worker, etc.) |
| `wait_event_type` | text | Wait event category (IO, Lock, LWLock, etc.) |
| `wait_event` | text | Specific wait event |
| `state` | text | Backend state (active, idle, etc.) |
| `count` | int | Number of backends in this state |

**`pgfr_record.activity_samples_ring`** -- Active session samples (slots x 25 rows)

| Column | Type | Description |
|--------|------|-------------|
| `slot_id` | int | Ring buffer slot index |
| `row_num` | int | Row within slot (1-25) |
| `pid` | int | Backend process ID |
| `usename` | text | User name |
| `application_name` | text | Application name |
| `client_addr` | inet | Client IP address |
| `backend_type` | text | Backend type |
| `state` | text | Backend state |
| `wait_event_type` | text | Wait event category |
| `wait_event` | text | Specific wait event |
| `backend_start` | timestamptz | When backend started |
| `xact_start` | timestamptz | When current transaction started |
| `query_start` | timestamptz | When current query started |
| `state_change` | timestamptz | When state last changed |
| `query_preview` | text | Truncated query text |

**`pgfr_record.lock_samples_ring`** -- Lock contention samples (slots x 100 rows)

| Column | Type | Description |
|--------|------|-------------|
| `slot_id` | int | Ring buffer slot index |
| `row_num` | int | Row within slot (1-100) |
| `blocked_pid` | int | PID of blocked backend |
| `blocked_user` | text | User of blocked backend |
| `blocked_app` | text | Application name of blocked backend |
| `blocked_query_preview` | text | Truncated query of blocked backend |
| `blocked_duration` | interval | How long the backend has been blocked |
| `blocking_pid` | int | PID of blocking backend |
| `blocking_user` | text | User of blocking backend |
| `blocking_app` | text | Application name of blocking backend |
| `blocking_query_preview` | text | Truncated query of blocking backend |
| `lock_type` | text | Lock type (relation, transactionid, etc.) |
| `locked_relation_oid` | oid | OID of locked relation |

### Archives (durable, 7-day default retention)

Archives preserve raw ring buffer samples at full resolution for forensic analysis. Archived every 15 minutes by default.

- **`pgfr_record.wait_samples_archive`** -- Same columns as `wait_samples_ring` plus `id` (bigserial), `sample_id`, `captured_at`
- **`pgfr_record.activity_samples_archive`** -- Same columns as `activity_samples_ring` plus `id` (bigserial), `sample_id`, `captured_at`
- **`pgfr_record.lock_samples_archive`** -- Same columns as `lock_samples_ring` plus `id` (bigserial), `sample_id`, `captured_at`

### Aggregates (durable, 7-day default retention)

Aggregates summarize ring buffer data into 5-minute windows.

**`pgfr_record.wait_event_aggregates`**

| Column | Type | Description |
|--------|------|-------------|
| `id` | bigserial | Row ID |
| `start_time` | timestamptz | Window start |
| `end_time` | timestamptz | Window end |
| `backend_type` | text | Backend type |
| `wait_event_type` | text | Wait event category |
| `wait_event` | text | Specific wait event |
| `state` | text | Backend state |
| `sample_count` | int | Samples in window |
| `total_waiters` | bigint | Total waiters across samples |
| `avg_waiters` | numeric | Average waiters per sample |
| `max_waiters` | int | Peak waiters in window |
| `pct_of_samples` | numeric | Percentage of samples with this event |

**`pgfr_record.lock_aggregates`**

| Column | Type | Description |
|--------|------|-------------|
| `id` | bigserial | Row ID |
| `start_time` | timestamptz | Window start |
| `end_time` | timestamptz | Window end |
| `blocked_user` | text | Blocked user |
| `blocking_user` | text | Blocking user |
| `lock_type` | text | Lock type |
| `locked_relation_oid` | oid | Locked relation OID |
| `occurrence_count` | int | Occurrences in window |
| `max_duration` | interval | Longest block duration |
| `avg_duration` | interval | Average block duration |
| `sample_query` | text | Sample blocked query |

**`pgfr_record.activity_aggregates`**

| Column | Type | Description |
|--------|------|-------------|
| `id` | bigserial | Row ID |
| `start_time` | timestamptz | Window start |
| `end_time` | timestamptz | Window end |
| `query_preview` | text | Truncated query |
| `occurrence_count` | int | Occurrences in window |
| `max_duration` | interval | Longest query duration |
| `avg_duration` | interval | Average query duration |

### Snapshots (durable, 30-day default retention)

**`pgfr_record.snapshots`** -- System-level statistics (WAL, checkpoints, I/O, connections, conflicts)

| Column | Type | Description |
|--------|------|-------------|
| `id` | serial | Snapshot ID |
| `captured_at` | timestamptz | Capture timestamp |
| `pg_version` | int | PostgreSQL major version |
| `wal_records` | bigint | Cumulative WAL records |
| `wal_fpi` | bigint | Cumulative full-page images |
| `wal_bytes` | bigint | Cumulative WAL bytes |
| `wal_write_time` | float8 | Cumulative WAL write time (ms) |
| `wal_sync_time` | float8 | Cumulative WAL sync time (ms) |
| `checkpoint_lsn` | pg_lsn | Last checkpoint LSN |
| `checkpoint_time` | timestamptz | Last checkpoint time |
| `ckpt_timed` | bigint | Timed checkpoints |
| `ckpt_requested` | bigint | Requested checkpoints |
| `ckpt_write_time` | float8 | Checkpoint write time (ms) |
| `ckpt_sync_time` | float8 | Checkpoint sync time (ms) |
| `ckpt_buffers` | bigint | Checkpoint buffers written |
| `bgw_buffers_clean` | bigint | Background writer buffers cleaned |
| `bgw_maxwritten_clean` | bigint | Background writer max-written stops |
| `bgw_buffers_alloc` | bigint | Buffers allocated |
| `bgw_buffers_backend` | bigint | Buffers written by backends |
| `bgw_buffers_backend_fsync` | bigint | Backend fsync calls |
| `autovacuum_workers` | int | Active autovacuum workers |
| `slots_count` | int | Replication slot count |
| `slots_max_retained_wal` | bigint | Max WAL retained by slots (bytes) |
| `io_*` | various | I/O stats by backend type: checkpointer, autovacuum, client, bgwriter (reads, writes, times, fsyncs) |
| `temp_files` | bigint | Temp files created |
| `temp_bytes` | bigint | Temp bytes written |
| `xact_commit` | bigint | Committed transactions |
| `xact_rollback` | bigint | Rolled back transactions |
| `blks_read` | bigint | Blocks read from disk |
| `blks_hit` | bigint | Blocks hit in buffer cache |
| `connections_active` | int | Active connections |
| `connections_total` | int | Total connections |
| `connections_max` | int | `max_connections` setting |
| `db_size_bytes` | bigint | Database size |
| `datfrozenxid_age` | int | Database frozen XID age |
| `archived_count` | bigint | WAL files archived |
| `last_archived_wal` | text | Last archived WAL file |
| `last_archived_time` | timestamptz | Last archive time |
| `failed_count` | bigint | Failed archive attempts |
| `last_failed_wal` | text | Last failed WAL file |
| `last_failed_time` | timestamptz | Last failure time |
| `archiver_stats_reset` | timestamptz | Archiver stats reset time |
| `confl_tablespace` | bigint | Tablespace conflicts (replicas) |
| `confl_lock` | bigint | Lock conflicts (replicas) |
| `confl_snapshot` | bigint | Snapshot conflicts (replicas) |
| `confl_bufferpin` | bigint | Buffer pin conflicts (replicas) |
| `confl_deadlock` | bigint | Deadlock conflicts (replicas) |
| `confl_active_logicalslot` | bigint | Logical slot conflicts (replicas) |
| `max_catalog_oid` | bigint | Highest catalog OID |
| `large_object_count` | bigint | Number of large objects |

**`pgfr_record.statement_snapshots`** -- Per-query statistics from pg_stat_statements

| Column | Type | Description |
|--------|------|-------------|
| `snapshot_id` | int | FK to snapshots |
| `queryid` | bigint | Query identifier |
| `userid` | oid | User OID |
| `dbid` | oid | Database OID |
| `query_preview` | text | Truncated query text |
| `calls` | bigint | Cumulative call count |
| `total_exec_time` | float8 | Cumulative execution time (ms) |
| `min_exec_time` | float8 | Minimum execution time (ms) |
| `max_exec_time` | float8 | Maximum execution time (ms) |
| `mean_exec_time` | float8 | Mean execution time (ms) |
| `rows` | bigint | Cumulative rows returned |
| `shared_blks_hit` | bigint | Shared buffer hits |
| `shared_blks_read` | bigint | Shared blocks read |
| `shared_blks_dirtied` | bigint | Shared blocks dirtied |
| `shared_blks_written` | bigint | Shared blocks written |
| `temp_blks_read` | bigint | Temp blocks read |
| `temp_blks_written` | bigint | Temp blocks written |
| `blk_read_time` | float8 | Block read time (ms) |
| `blk_write_time` | float8 | Block write time (ms) |
| `wal_records` | bigint | WAL records generated |
| `wal_bytes` | numeric | WAL bytes generated |

**`pgfr_record.table_snapshots`** -- Per-table statistics

| Column | Type | Description |
|--------|------|-------------|
| `snapshot_id` | int | FK to snapshots |
| `schemaname` | text | **Deprecated** -- use `relid::regclass` |
| `relname` | text | **Deprecated** -- use `relid::regclass` |
| `relid` | oid | Table OID |
| `seq_scan` | bigint | Sequential scans |
| `seq_tup_read` | bigint | Tuples read by seq scans |
| `idx_scan` | bigint | Index scans |
| `idx_tup_fetch` | bigint | Tuples fetched by index scans |
| `n_tup_ins` | bigint | Tuples inserted |
| `n_tup_upd` | bigint | Tuples updated |
| `n_tup_del` | bigint | Tuples deleted |
| `n_tup_hot_upd` | bigint | HOT updates |
| `n_live_tup` | bigint | Live tuples |
| `n_dead_tup` | bigint | Dead tuples |
| `n_mod_since_analyze` | bigint | Modifications since last analyze |
| `vacuum_count` | bigint | Manual vacuum count |
| `autovacuum_count` | bigint | Autovacuum count |
| `analyze_count` | bigint | Manual analyze count |
| `autoanalyze_count` | bigint | Autoanalyze count |
| `last_vacuum` | timestamptz | Last manual vacuum |
| `last_autovacuum` | timestamptz | Last autovacuum |
| `last_analyze` | timestamptz | Last manual analyze |
| `last_autoanalyze` | timestamptz | Last autoanalyze |
| `relfrozenxid_age` | int | Table frozen XID age |
| `reltuples` | bigint | Estimated live rows (from `pg_class`) |
| `vacuum_running` | bool | Whether vacuum is currently running |
| `last_vacuum_duration_ms` | bigint | Duration of last vacuum (ms) |
| `table_size_bytes` | bigint | Table size excluding indexes |
| `total_size_bytes` | bigint | Table + index size |
| `indexes_size_bytes` | bigint | Index size |

**`pgfr_record.index_snapshots`** -- Per-index statistics

| Column | Type | Description |
|--------|------|-------------|
| `snapshot_id` | int | FK to snapshots |
| `schemaname` | text | **Deprecated** -- use `relid::regclass` |
| `relname` | text | **Deprecated** -- use `relid::regclass` |
| `indexrelname` | text | **Deprecated** -- use `indexrelid::regclass` |
| `relid` | oid | Table OID |
| `indexrelid` | oid | Index OID |
| `idx_scan` | bigint | Index scans |
| `idx_tup_read` | bigint | Index tuples read |
| `idx_tup_fetch` | bigint | Index tuples fetched |
| `index_size_bytes` | bigint | Index size (bytes) |

**`pgfr_record.config_snapshots`** -- PostgreSQL configuration

| Column | Type | Description |
|--------|------|-------------|
| `snapshot_id` | int | FK to snapshots |
| `name` | text | Setting name |
| `setting` | text | Setting value |
| `unit` | text | Setting unit |
| `source` | text | Setting source (e.g., `configuration file`) |
| `sourcefile` | text | Config file path |

**`pgfr_record.db_role_config_snapshots`** -- Database/role configuration overrides

| Column | Type | Description |
|--------|------|-------------|
| `snapshot_id` | int | FK to snapshots |
| `database_name` | text | Database name (empty for global) |
| `role_name` | text | Role name (empty for database-level) |
| `parameter_name` | text | Parameter name |
| `parameter_value` | text | Parameter value |

**`pgfr_record.replication_snapshots`** -- Replication state

| Column | Type | Description |
|--------|------|-------------|
| `snapshot_id` | int | FK to snapshots |
| `pid` | int | WAL sender PID |
| `client_addr` | inet | Replica address |
| `application_name` | text | Application name |
| `state` | text | Replication state |
| `sync_state` | text | Sync mode |
| `sent_lsn` | pg_lsn | Last LSN sent |
| `write_lsn` | pg_lsn | Last LSN written by replica |
| `flush_lsn` | pg_lsn | Last LSN flushed by replica |
| `replay_lsn` | pg_lsn | Last LSN replayed by replica |
| `write_lag` | interval | Write lag |
| `flush_lag` | interval | Flush lag |
| `replay_lag` | interval | Replay lag |

**`pgfr_record.vacuum_progress_snapshots`** -- Vacuum progress

| Column | Type | Description |
|--------|------|-------------|
| `snapshot_id` | int | FK to snapshots |
| `pid` | int | Vacuum worker PID |
| `datid` | oid | Database OID |
| `datname` | text | Database name |
| `relid` | oid | Table OID |
| `relname` | text | Table name |
| `phase` | text | Vacuum phase |
| `heap_blks_total` | bigint | Total heap blocks |
| `heap_blks_scanned` | bigint | Heap blocks scanned |
| `heap_blks_vacuumed` | bigint | Heap blocks vacuumed |
| `index_vacuum_count` | bigint | Index vacuum passes |
| `max_dead_tuples` | bigint | Max dead tuples per pass |
| `num_dead_tuples` | bigint | Current dead tuples found |

### Internal

**`pgfr_record.config`** -- Flight Recorder configuration (key-value store)

| Column | Type | Description |
|--------|------|-------------|
| `key` | text | Setting name (PK) |
| `value` | text | Setting value |
| `updated_at` | timestamptz | Last modified |

**`pgfr_record.collection_stats`** -- Collection job metrics

| Column | Type | Description |
|--------|------|-------------|
| `id` | serial | Row ID |
| `collection_type` | text | `snapshot` or `sample` |
| `started_at` | timestamptz | Job start time |
| `completed_at` | timestamptz | Job end time |
| `duration_ms` | int | Duration in milliseconds |
| `success` | bool | Whether collection succeeded |
| `error_message` | text | Error message if failed |
| `skipped` | bool | Whether collection was skipped |
| `skipped_reason` | text | Reason for skip (load shedding, circuit breaker, etc.) |
| `sections_total` | int | Total sections attempted |
| `sections_succeeded` | int | Sections that succeeded |

**`pgfr_record.relation_names`** -- OID to relation name mappings (populated at export time)

| Column | Type | Description |
|--------|------|-------------|
| `oid` | oid | Relation OID (PK) |
| `nspname` | text | Schema name |
| `relname` | text | Relation name |

### Deprecated columns

The following columns are **deprecated** and will be NULL in new data:

| Table | Deprecated Columns | Use Instead |
|-------|--------------------|--------------------------------------------|
| `table_snapshots` | `schemaname`, `relname` | `relid::regclass` or `relation_names` lookup |
| `index_snapshots` | `schemaname`, `relname`, `indexrelname` | `relid::regclass`, `indexrelid::regclass` |

This eliminates `pg_catalog` joins during collection, avoiding even `AccessShareLock`. Existing data with names is preserved.

## Configuration settings

Settings are stored in `pgfr_record.config`. Profiles set groups of related settings. Update individual settings with:

```sql
UPDATE pgfr_record.config SET value = '300' WHERE key = 'sample_interval_seconds';
```

### Core settings

| Setting | Default | Description |
|---------|---------|-------------|
| `schema_version` | `2.28` | Schema version (do not modify) |
| `mode` | `normal` | Collection mode: `normal`, `light`, `emergency`, `kill` |
| `enabled` | `true` | Whether collection is enabled |

### Collection intervals and retention

| Setting | Default | Description |
|---------|---------|-------------|
| `sample_interval_seconds` | `60` | Seconds between ring buffer samples |
| `ring_buffer_slots` | `120` | Ring buffer slot count (72-2880) |
| `retention_snapshots_days` | `30` | Snapshot retention (days) |
| `retention_samples_days` | `7` | Archive/aggregate retention (days) |
| `retention_statements_days` | `30` | Statement snapshot retention (days) |
| `retention_collection_stats_days` | `30` | Collection stats retention (days) |
| `aggregate_retention_days` | `7` | Aggregate retention (days) |
| `archive_samples_enabled` | `true` | Enable raw sample archiving |
| `archive_sample_frequency_minutes` | `15` | How often to archive ring buffer samples |
| `archive_retention_days` | `7` | Archive retention (days) |
| `archive_activity_samples` | `true` | Archive activity samples |
| `archive_lock_samples` | `true` | Archive lock samples |
| `archive_wait_samples` | `true` | Archive wait samples |

### Safety thresholds

| Setting | Default | Description |
|---------|---------|-------------|
| `circuit_breaker_threshold_ms` | `1000` | Max collection duration before circuit breaker trips |
| `circuit_breaker_window_minutes` | `15` | Window for circuit breaker evaluation |
| `load_shedding_active_pct` | `70` | Connection % threshold for load shedding |
| `lock_timeout_ms` | `100` | Lock timeout for collection queries |
| `lock_timeout_strategy` | `fail_fast` | Lock timeout strategy |
| `section_timeout_ms` | `250` | Per-section timeout within collection |
| `statement_timeout_ms` | `1000` | Statement timeout for collection queries |
| `work_mem_kb` | `2048` | `work_mem` for collection queries (KB) |

### Pre-flight checks

| Setting | Default | Description |
|---------|---------|-------------|
| `check_pss_conflicts` | `true` | Check for pg_stat_statements conflicts |

### Schema size limits

| Setting | Default | Description |
|---------|---------|-------------|
| `schema_size_check_enabled` | `true` | Enable schema size monitoring |
| `schema_size_use_percentage` | `true` | Use percentage-based limits |
| `schema_size_percentage` | `5.0` | Max schema size as % of database |
| `schema_size_min_mb` | `1000` | Minimum size threshold (MB) |
| `schema_size_max_mb` | `10000` | Maximum size threshold (MB) |
| `schema_size_warning_mb` | `5000` | Warning threshold (MB) |
| `schema_size_critical_mb` | `10000` | Critical threshold (MB) |

### Statement collection

| Setting | Default | Description |
|---------|---------|-------------|
| `statements_enabled` | `auto` | Enable pg_stat_statements collection: `auto`, `true`, `false` |
| `statements_top_n` | `20` | Number of top queries to collect per snapshot |
| `statements_ranking_metric` | `buffers` | Metric for ranking queries: `buffers` or `time` |
| `statements_interval_minutes` | `1` | Minutes between statement collections |
| `statements_min_calls` | `1` | Minimum call count to include a query |

### Table and index collection

| Setting | Default | Description |
|---------|---------|-------------|
| `table_stats_mode` | `top_n` | Table collection mode |
| `table_stats_activity_threshold` | `0` | Minimum activity to include a table |
| `table_stats_top_n` | `50` | Number of top tables to collect |
| `index_stats_enabled` | `true` | Enable index stats collection |
| `config_snapshots_enabled` | `true` | Enable config snapshots |
| `db_role_config_snapshots_enabled` | `true` | Enable db/role config snapshots |
| `collect_database_size` | `true` | Collect database size |
| `collect_connection_metrics` | `true` | Collect connection counts |

### Load shedding thresholds

| Setting | Default | Description |
|---------|---------|-------------|
| `skip_locks_threshold` | `50` | Skip lock collection if > N blocked backends |
| `skip_activity_conn_threshold` | `100` | Skip activity collection if > N active connections |

### Anomaly detection

| Setting | Default | Description |
|---------|---------|-------------|
| `storm_threshold_multiplier` | `3.0` | Baseline multiplier for query storm detection |
| `storm_lookback_interval` | `1 hour` | Recent window for storm comparison |
| `storm_baseline_days` | `7` | Historical baseline for storm detection |
| `storm_severity_low_max` | `5.0` | Max multiplier for LOW severity |
| `storm_severity_medium_max` | `10.0` | Max multiplier for MEDIUM severity |
| `storm_severity_high_max` | `50.0` | Max multiplier for HIGH severity |
| `regression_threshold_pct` | `50.0` | Min % change for regression detection |
| `regression_lookback_interval` | `1 hour` | Recent window for regression comparison |
| `regression_baseline_days` | `7` | Historical baseline for regression detection |
| `regression_severity_low_max` | `200.0` | Max % for LOW severity |
| `regression_severity_medium_max` | `500.0` | Max % for MEDIUM severity |
| `regression_severity_high_max` | `1000.0` | Max % for HIGH severity |
| `regression_detection_metric` | `buffers` | Metric for regression detection: `buffers` or `time` |

### Vacuum control

| Setting | Default | Description |
|---------|---------|-------------|
| `vacuum_control_enabled` | `true` | Enable vacuum control state tracking |
| `vacuum_control_dead_tuple_budget_pct` | `5` | Dead tuple budget as % of live tuples |
| `vacuum_control_min_scale_factor` | `0.001` | Minimum recommended scale factor |
| `vacuum_control_max_scale_factor` | `0.2` | Maximum recommended scale factor |
| `vacuum_control_hysteresis_pct` | `25` | Hysteresis band for scale factor changes (%) |
| `vacuum_control_rate_limit_minutes` | `60` | Minimum minutes between recommendation changes |
| `vacuum_control_catchup_budget_hours` | `4` | Target hours to clear dead tuple backlog in catch_up mode |

### Alerts and capacity

| Setting | Default | Description |
|---------|---------|-------------|
| `alert_enabled` | `false` | Enable alert checking |
| `alert_circuit_breaker_count` | `5` | Circuit breaker trips before alert |
| `alert_schema_size_mb` | `8000` | Schema size alert threshold (MB) |
| `capacity_planning_enabled` | `true` | Enable capacity planning |
| `capacity_thresholds_warning_pct` | `60` | Capacity warning threshold (%) |
| `capacity_thresholds_critical_pct` | `80` | Capacity critical threshold (%) |

## Configuration profiles

Profiles configure groups of related settings for different environments. Key differences between profiles:

| Setting | default | production_safe | development | troubleshooting | minimal_overhead |
|---------|---------|-----------------|-------------|-----------------|------------------|
| `sample_interval_seconds` | 60 | 300 | 60 | 60 | 300 |
| `load_shedding_active_pct` | 70 | 60 | 70 | disabled | 50 |
| `circuit_breaker_threshold_ms` | 1000 | 800 | 1000 | 2000 | 500 |
| `enable_locks` | true | false | true | true | false |
| `enable_progress` | true | false | true | true | false |
| `retention_snapshots_days` | 30 | 30 | 7 | 7 | 7 |
| `retention_samples_days` | 7 | 7 | 3 | 7 | 3 |
| `section_timeout_ms` | 250 | 200 | 250 | 500 | 100 |
| `statement_timeout_ms` | 1000 | 800 | 1000 | 2000 | 500 |
| `work_mem_kb` | 2048 | 1024 | 2048 | 4096 | 1024 |
| `statements_interval_minutes` | 1 | 15 | 1 | 2 | 15 |
| `statements_min_calls` | 1 | 5 | 1 | 1 | 10 |
| `table_stats_top_n` | 50 | 30 | 50 | 100 | 20 |
| `table_stats_enabled` | true | true | true | true | false |
| `index_stats_enabled` | true | true | true | true | false |

```sql
-- List all profiles and their settings
SELECT * FROM pgfr_record.list_profiles();

-- Preview what a profile would change
SELECT * FROM pgfr_record.explain_profile('production_safe');

-- Apply a profile
SELECT * FROM pgfr_record.apply_profile('production_safe');

-- Check which profile matches current settings
SELECT * FROM pgfr_record.get_current_profile();
```

## Safety features

### Collection modes

| Mode | Behavior |
|------|----------|
| `normal` | Full collection: snapshots, samples, locks, progress, statements |
| `light` | Reduced: skips lock contention and vacuum progress collection |
| `emergency` | Minimal: snapshots only, no ring buffer sampling |
| `kill` | All collection disabled |

```sql
SELECT pgfr_record.set_mode('kill');      -- Emergency stop
SELECT pgfr_record.set_mode('normal');    -- Resume
SELECT * FROM pgfr_record.get_mode();     -- Check current mode
```

### Automatic protections

| Protection | Trigger | Behavior |
|------------|---------|----------|
| **Circuit Breaker** | Collection exceeds `circuit_breaker_threshold_ms` (default 1s) | Skips next collection cycle |
| **Load Shedding** | Active connections exceed `load_shedding_active_pct` of `max_connections` | Skips entire collection cycle |
| **Section Timeouts** | Per-query timeout (default 250ms) | Prevents catalog lock hangs within collection |
| **Job Timeouts** | Outer `statement_timeout` on all pg_cron jobs (5-60s) | Kills hung collection as last-resort safety net |

### Manual mode control

Use `pgfr_record.set_mode()` to manually switch collection modes: `normal`, `light`, `emergency`, `kill`.
