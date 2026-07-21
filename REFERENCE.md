# pg_flight_recorder Reference

[![GitHub release](https://img.shields.io/github/v/release/dventimisupabase/pg_flight_recorder)](https://github.com/dventimisupabase/pg_flight_recorder/releases/latest)
[![Test Suite](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/test.yml/badge.svg)](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/test.yml)
[![Lint](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/lint.yml/badge.svg)](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/lint.yml)

Complete reference for [pg_flight_recorder](README.md). For installation and getting started, see the [README](README.md). For per-extension overviews, see [pgfr_record](pgfr_record/README.md) and [pgfr_analyze](pgfr_analyze/README.md).

## Functions: pgfr_record (core)

### Control

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_record.enable()` | `text` | Start collection jobs via pg_cron |
| `pgfr_record.disable()` | `text` | Stop collection jobs |
| `pgfr_record.health_check()` | `record` | System health status with diagnostics |
| `pgfr_record.set_mode(mode text)` | `text` | Set collection mode: `normal`, `light`, or `emergency` |
| `pgfr_record.get_mode()` | `record` | Get current collection mode |
| `pgfr_record.validate_config()` | `record` | Validate all configuration settings |
| `pgfr_record.config_recommendations()` | `record` | Get configuration recommendations based on system state |

### Collection

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_record.snapshot()` | `timestamptz` | Durable snapshot: WAL, checkpoints, I/O, tables, indexes, statements, replication, config |
| `pgfr_record.sample_ring()` | `timestamptz` | Sampled activity: wait events, active sessions, locks into the v2 ring (TRUNCATE-rotated partitions) |
| `pgfr_record.rotate_ring()` | `void` | Advance the v2 ring buffer by one slot (TRUNCATE the slot two steps ahead) |
| `pgfr_record.cleanup()` | `record` | Remove expired data based on retention settings |

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
| `pgfr_record.validate_ring_configuration()` | `record` | Validate ring buffer retention, batching, CPU, and memory |

The v2 ring uses TRUNCATE-rotation on LIST-partitioned tables; partition
maintenance is handled by the `pgfr_truncate_partitions`,
`pgfr_drop_ancient_partitions`, and `pgfr_precreate_partitions` cron jobs.
The legacy `ring_buffer_health()`, `rebuild_ring_buffers()`, and
`configure_ring_autovacuum()` functions were retired with the legacy
120-slot ring (they targeted pre-allocated slot rows that no longer exist).

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
| `pgfr_analyze.recent_waits_current()` | `record` | Current wait event data from the v2 ring (decoded via wait_event_map) |
| `pgfr_analyze.recent_activity_current()` | `record` | Current activity data from the v2 ring |
| `pgfr_analyze.recent_locks_current()` | `record` | Current lock data from the v2 ring (decoded via lock_type_map) |

### Reporting

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_analyze.report(interval)` | `text` | Comprehensive diagnostic report for a time window |
| `pgfr_analyze.report(start timestamptz, end timestamptz)` | `text` | Diagnostic report for a specific time range |
| `pgfr_analyze.summary_report(start timestamptz, end timestamptz)` | `record` | Summary statistics |
| `pgfr_analyze.performance_report(start timestamptz, end timestamptz)` | `record` | Performance-focused report |
| `pgfr_analyze.anomaly_report(start timestamptz, end timestamptz)` | `record` | Anomaly analysis: checkpoints, buffer pressure, temp spills, locks, XID + MultiXID wraparound risk, xmin horizon stalls (data + catalog, four severity tiers; cause precedes wraparound symptom) |
| `pgfr_analyze.check_alerts()` | `record` | Check active alert conditions |
| `pgfr_analyze.consumption_trend_report(datname text default current_database())` | `text` | Specific-consumption drift report against the database's own baseline: both the 28-day/daily and 84-day/weekly windows, per basket metric |

### Forensics

| Function | Returns | Description |
|----------|---------|-------------|
| `pgfr_analyze.what_happened_at(ts timestamptz)` | `record` | Point-in-time analysis: snapshots, waits, activity, locks around a timestamp |
| `pgfr_analyze.incident_timeline(start timestamptz, end timestamptz)` | `record` | Reconstructed event timeline for an incident window |
| `pgfr_analyze.blast_radius(queryid bigint)` | `record` | Impact analysis for a specific query: I/O, CPU, lock, temp file effects |
| `pgfr_analyze.blast_radius_report(interval)` | `text` | Text report on high-impact queries |
| `pgfr_analyze.xmin_horizon_history(start timestamptz, end timestamptz)` | `record` | Timeline of xmin holders within a window. Joins three sidecars + replication via `UNION ALL`; `horizon_type` (`'data'` / `'catalog'` / `'both'`) disambiguates slot rows. Pushes down `sample_ts` predicate for partition pruning. |
| `pgfr_analyze.current_xmin_horizon_holder()` | `record` | Quick-answer reader. Returns zero rows on a healthy cluster, otherwise one row for the dominant holder per cross-source priority (`slot > prepared > activity > replication`). |

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
| `pgfr_record.consumption_deltas` | `consumption_snapshots_v2` | Reset-guarded per-tick component deltas backing `consumption_flows` and the daily rollup |
| `pgfr_record.consumption_flows` | `consumption_deltas` | Live per-tick flow rates and efficiency ratios (reset-guarded) |
| `pgfr_record.consumption_daily_flows` | `consumption_daily_rollups` | Daily-grain ratios reconstructed from summed components (Σnum/Σden, never averaged from daily ratios) |
| `pgfr_record.consumption_weekly_flows` | `consumption_daily_rollups` | Weekly-grain ratios, rolling 7-day buckets counting back from `current_date`, one tier up from the daily flows |

### pgfr_analyze

| View | Source | Description |
|------|--------|-------------|
| `pgfr_analyze.capacity_dashboard` | Snapshots | Resource utilization overview: connections, disk, WAL, transactions |
| `pgfr_analyze.consumption_metric_series` | `consumption_daily_flows` | Long-format `(rollup_date, datname, metric_name, value)` unpivot of the 8 basket metrics |
| `pgfr_analyze.consumption_weekly_metric_series` | `consumption_weekly_flows` | Long-format `(week_end_date, datname, metric_name, value)` unpivot, weekly grain |

## Tables

### Ring buffer (LIST-partitioned by slot, TRUNCATE-rotated)

**`pgfr_record.ring_config`** -- Singleton config row for the v2 ring (num_slots, rotation_period).

**`pgfr_record.wait_samples`** -- Encoded wait event samples (one row per active wait group per tick)

| Column | Type | Description |
|--------|------|-------------|
| `sample_ts` | int4 | Seconds since `pgfr_record.epoch()` |
| `datid` | oid | Database OID |
| `active_count` | smallint | Total active backends in this sample |
| `data` | integer[] | Encoded `[-wait_id, count, qid, qid, …, -next_wait_id, count, …]` |
| `slot` | smallint | Ring slot (LIST partition key) |

Decode `data` via `pgfr_record.wait_event_map` to get `(state, type, event)` per wait_id.

**`pgfr_record.activity_samples`** -- Active session samples (one row per backend per tick)

| Column | Type | Description |
|--------|------|-------------|
| `sample_ts` | int4 | Seconds since `pgfr_record.epoch()` |
| `pid` | int4 | Backend process ID |
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
| `slot` | smallint | Ring slot (LIST partition key) |

**`pgfr_record.lock_samples`** -- Lock contention samples (one row per blocked/blocking pair per tick)

| Column | Type | Description |
|--------|------|-------------|
| `sample_ts` | int4 | Seconds since `pgfr_record.epoch()` |
| `blocked_pid` | int4 | PID of blocked backend |
| `blocked_qid` | int4 | Query map id for blocked backend's query |
| `blocked_duration_s` | int4 | Seconds the backend has been blocked |
| `blocking_pid` | int4 | PID of blocking backend |
| `blocking_qid` | int4 | Query map id for blocking backend's query |
| `lock_type` | smallint | Lock type code (decode via `lock_type_map`) |
| `locked_relation_oid` | oid | OID of locked relation |
| `slot` | smallint | Ring slot (LIST partition key) |

The v2 ring drops the legacy per-row `usename`/`app_name`/`query_preview` for
lock samples — only `pid` and lookup ids are stored. Use `pgfr_analyze.recent_locks_current()`
for a column-compatible reader (lost columns return NULL).

### Ring rollups (RANGE-partitioned by `sample_ts`, archive-tier retention)

Durable, bounded-size summaries of ring buffer data beyond the ring's 2h window, written by `_flush_ring_slot_to_rollups()` from `rotate_ring()` right before it TRUNCATEs the slot being rotated out -- no separate cron job, no persisted flush watermark. The `_archive_v2` name gives these `retention_archive_days`-tier retention from `_partition_inventory()` (default 7 days) with no new shared infrastructure; despite the name, these are bounded aggregates, not full-resolution archives.

**`pgfr_record.wait_event_rollups_archive_v2`** -- one row per `(backend_type, wait_event_type, wait_event)` per rotation window

| Column | Type | Description |
|--------|------|-------------|
| `sample_ts` | int4 | Window end, seconds since `epoch()`; RANGE partition key |
| `start_time` / `end_time` | timestamptz | Rotation window bounds |
| `backend_type` | text | Sourced from `wait_event_map.state` |
| `wait_event_type` / `wait_event` | text | Wait event category and name |
| `sample_count` | integer | Distinct samples this wait group appeared in |
| `total_waiters` / `avg_waiters` / `max_waiters` | bigint / numeric / integer | Waiter count stats over the window |
| `pct_of_samples` | numeric | Share of the window's total samples |

**`pgfr_record.lock_rollups_archive_v2`** -- one row per `(lock_type, locked_relation_oid)` per rotation window

| Column | Type | Description |
|--------|------|-------------|
| `sample_ts` | int4 | Window end, seconds since `epoch()`; RANGE partition key |
| `start_time` / `end_time` | timestamptz | Rotation window bounds |
| `lock_type` | text | Decoded via `lock_type_map` |
| `locked_relation_oid` | oid | OID of the locked relation |
| `occurrence_count` | integer | Samples this pair appeared in |
| `max_duration` / `avg_duration` | interval | Blocked-duration stats over the window |

No `blocked_user`/`blocking_user`/`sample_query` columns: the v2 ring's `lock_samples` stores pids and lookup ids, not usernames or query text.

**`pgfr_record.activity_rollups_archive_v2`** -- one row per `(backend_type, state, duration_bucket)` per rotation window

| Column | Type | Description |
|--------|------|-------------|
| `sample_ts` | int4 | Window end, seconds since `epoch()`; RANGE partition key |
| `start_time` / `end_time` | timestamptz | Rotation window bounds |
| `backend_type` / `state` | text | Backend type and state |
| `duration_bucket` | text | `<1s` / `1s-10s` / `10s-60s` / `1m-10m` / `10m+`, how long the session had been running its current query at sample time |
| `occurrence_count` | integer | Samples in this bucket |
| `max_duration` / `avg_duration` | interval | Running-time stats over the window |

Grouped by concurrency/duration profile rather than raw `query_preview` text (unbounded cardinality, and redundant with `statement_snapshots_v2`'s queryid-based stats).

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
| `datfrozenxid_age` | int | Database frozen XID age (`age(datfrozenxid)`) |
| `datminmxid_age` | int | Database MultiXact ID age (`mxid_age(datminmxid)`) |
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
| `activity_xmin` / `activity_xmin_age` | xid / bigint | Oldest `pg_stat_activity.backend_xmin` (self- and parallel-worker-excluded) |
| `slot_xmin` / `slot_xmin_age` | xid / bigint | Oldest `pg_replication_slots.xmin` |
| `slot_catalog_xmin` / `slot_catalog_xmin_age` | xid / bigint | Oldest `pg_replication_slots.catalog_xmin` (logical-decoding catalog cleanup horizon) |
| `replication_xmin` / `replication_xmin_age` | xid / bigint | Oldest `pg_stat_replication.backend_xmin` (physical walsenders only) |
| `prepared_xmin` / `prepared_xmin_age` | xid / bigint | Oldest `pg_prepared_xacts.transaction` |
| `xmin_data_horizon_age` | bigint | `GREATEST` of the four data-source ages |
| `xmin_any_horizon_age` | bigint | `GREATEST(xmin_data_horizon_age, slot_catalog_xmin_age)` |
| `xmin_horizon_detail` | jsonb | `{source, age, holder: {...}}` describing the dominant holder. `source` ∈ `activity` / `slot` / `slot_catalog` / `prepared` / `replication`. NULL when no holder. |

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
| `relfrozenxid_age` | int | Table frozen XID age (`age(c.relfrozenxid)`) |
| `relminmxid_age` | int | Table MultiXact ID age (`mxid_age(c.relminmxid)`) |
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
| `backend_xmin` / `backend_xmin_age` | xid / bigint | Walsender's `backend_xmin` and `age()` |
| `slot_name` | text | Slot driving this walsender (joined from `pg_replication_slots.active_pid`) |
| `is_logical_walsender` | boolean | `true` for logical-decoding walsenders (excluded from the `replication_xmin` aggregate; the slot's own xmin is captured via `slot_xmin` / `slot_catalog_xmin` on the same snapshot row) |

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

### Consumption ledger

**`pgfr_record.consumption_snapshots_v2`** -- global block/WAL/tuple flow ledger, daily RANGE-partitioned by `sample_ts`, one row per `snapshot()` tick. No FK (`snapshot_id` is a logical reference to `snapshots_v2`). Primary-only -- no rows are written while `pg_is_in_recovery()`.

| Column | Type | Description |
|--------|------|-------------|
| `snapshot_id` | bigint | Logical reference to `snapshots_v2.snapshot_id` (no FK) |
| `sample_ts` | int4 | Seconds since `epoch()`; RANGE partition key |
| `captured_at` | timestamptz | Capture timestamp |
| `pg_version` | int | PostgreSQL major version |
| `datname` | text | Scope label for the per-database lanes below |
| `wal_lsn` | pg_lsn | `pg_current_wal_lsn()` -- ledger of record, valid across stats resets |
| `tup_returned` / `tup_fetched` / `tup_inserted` / `tup_updated` / `tup_deleted` | bigint | Cumulative tuple flow (`pg_stat_database`, per-database) |
| `xact_commit` / `xact_rollback` | bigint | Cumulative transactions (per-database) |
| `blks_hit` / `blks_read` | bigint | Cumulative block demand (per-database) |
| `blk_read_time_ms` / `blk_write_time_ms` | float8 | Cumulative block I/O time; 0 (not NULL) when `track_io_timing` is off |
| `temp_files` / `temp_bytes` | bigint | Cumulative temp file spill (per-database) |
| `wal_records` / `wal_fpi` / `wal_buffers_full` | bigint | WAL decomposition (`pg_stat_wal`, cluster-wide, advisory vs. `wal_lsn`) |
| `wal_bytes` | numeric | Advisory WAL byte decomposition (cluster-wide) |
| `wal_stats_reset` | timestamptz | Reset sentinel for the `wal_*` lane |
| `io_reads_client` / `io_writes_client` / `io_extends_client` / `io_fsyncs_client` | bigint | Client-backend I/O (`pg_stat_io`, object=relation, PG16+) |
| `io_reads_autovacuum` / `io_writes_autovacuum` | bigint | Autovacuum-worker I/O |
| `io_writes_checkpointer` / `io_fsyncs_checkpointer` | bigint | Checkpointer I/O |
| `io_writes_bgwriter` | bigint | Background writer I/O |
| `io_reads_total` / `io_writes_total` / `io_extends_total` | bigint | Cluster-wide totals across backend types; `io_reads_total` NULL on PG15 (no `pg_stat_io`) |
| `ckpt_num_timed` / `ckpt_num_requested` / `ckpt_buffers_written` | bigint | Checkpoint counters (`pg_stat_checkpointer` PG17+, `pg_stat_bgwriter` PG15-16) |
| `bgw_buffers_clean` / `bgw_maxwritten_clean` / `bgw_buffers_alloc` | bigint | Background writer counters |
| `ckpt_stats_reset` | timestamptz | Reset sentinel for the checkpointer/bgwriter lane |
| `db_stats_reset` | timestamptz | Reset sentinel for the per-database lane |
| `db_size_bytes` | bigint | `pg_database_size()` at capture time |
| `recorder_blks_hit` / `recorder_blks_read` | bigint | pgfr_record's own block footprint (self-accounting) |

`io_reads_total` is a request issued to the OS, not confirmed disk I/O -- the OS page cache may satisfy it. See `consumption_flows.os_read_blocks_per_s` / `os_write_blocks_per_s`.

**`pgfr_record.consumption_daily_rollups`** -- durable daily-grain rollup, one row per calendar day per `datname`, populated by `_rollup_consumption_daily()` from the daily `pgfr_cleanup` cron job (no separate job). Not partitioned, no retention -- tiny by construction (a decade is ~3,650 rows), meant to be kept indefinitely. Stores summed components, not ratios (see `consumption_daily_flows`).

| Column | Type | Description |
|--------|------|-------------|
| `rollup_date` | date | Calendar day (PK, with `datname`) |
| `datname` | text | Database name (PK) |
| `total_seconds` | int | Sum of valid tick intervals; use as the daily "_per_s" denominator instead of assuming 86400 |
| `valid_tick_count` | int | Count of ticks that contributed to this row |
| `blks_hit_sum` / `blks_read_sum` | bigint | Summed block demand |
| `tup_returned_sum` / `tup_mutated_sum` | bigint | Summed tuple flow (`tup_mutated` = inserted + updated + deleted) |
| `xact_commit_sum` / `xact_rollback_sum` | bigint | Summed transactions |
| `temp_bytes_sum` | bigint | Summed temp spill |
| `recorder_blks_hit_sum` / `recorder_blks_read_sum` | bigint | Summed self-accounting block footprint |
| `wal_bytes_sum` | numeric | Summed WAL bytes (LSN-diff based, ledger of record) |
| `wal_fpi_sum` | bigint | Summed WAL full-page images |
| `wal_bytes_advisory_sum` | numeric | Summed advisory WAL byte decomposition |
| `ckpt_num_timed_sum` / `ckpt_num_requested_sum` | bigint | Summed checkpoint counts |
| `io_writes_autovacuum_sum` / `io_writes_total_sum` | bigint | Summed write I/O (PG16+; NULL on PG15) |
| `db_size_bytes` | bigint | Day's last-observed database size (gauge, not a sum) |

### Consumption trends (pgfr_analyze)

**`pgfr_analyze.consumption_trends`** -- persisted trend assessments for the consumption ledger's 8-metric basket, one row per `(as_of_date, datname, metric_name, window_days)`, upserted on every refresh so history accumulates across days rather than being overwritten. Not partitioned, no retention -- tiny by construction, meant to be kept indefinitely.

| Column | Type | Description |
|--------|------|-------------|
| `as_of_date` | date | Date this assessment was computed (PK) |
| `datname` | text | Database name (PK) |
| `metric_name` | text | One of the 8 basket metrics (PK): `blocks_per_row_returned`, `wal_bytes_per_row_mutated`, `temp_bytes_per_xact`, `fpi_fraction`, `ckpt_requested_fraction`, `rollback_fraction`, `autovacuum_write_share`, `cache_hit_fraction` |
| `window_days` | integer | `28` (daily engine) or `84` (weekly engine) (PK) |
| `basket_version` | integer | Metric-basket schema version |
| `sample_count` | integer | Count of non-NULL periods (days or weeks) in the window |
| `baseline_start` / `baseline_end` | date | The window's fixed date range |
| `slope_pct_per_30d` | numeric | Theil-Sen slope (median of pairwise slopes), normalized to %/30d relative to the window's median value; NULL when `insufficient_data` |
| `classification` | text | `insufficient_data` / `stable` / `drift` / `step` / `composition` -- see below |
| `changepoint_date` | date | Set only when `classification = 'step'` |
| `composition_change` | boolean | Whether workload-shape indicators (`read_write_tuple_ratio`, `xact_per_s`, `rows_returned_per_xact`, `rows_mutated_per_xact`, `db_size_bytes`) shifted beyond `consumption_trend_shape_guard_pct` between the window's two fixed halves |
| `computed_at` | timestamptz | Timestamp of this row's (re)computation |

`classification` values: `stable` (no line or step fits meaningfully better than noise), `drift` (a gradual change -- a line fits at least as well as any step), `step` (a genuine level shift -- a two-level step fits meaningfully better than a line, by `consumption_trend_step_r2_margin`), `composition` (a step or drift was detected, but the workload shape also moved -- no fitness inference is safe), `insufficient_data` (fewer than `consumption_trend_min_days` / `consumption_trend_min_weeks` periods collected). Distinguishing `step` from `drift` compares model fit (R²), not shift magnitude -- a clean step and a linear ramp can produce the same shift-magnitude-to-variability ratio.

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
| `retention_archive_days` | `7` | Archive-tier partition retention (days). No active subscribers after the archive retirement, but kept as a placeholder for future archive-tier tables. |
| `retention_statements_days` | `30` | Statement snapshot retention (days) |
| `retention_collection_stats_days` | `30` | Collection stats retention (days) |

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

### XID / MultiXID wraparound thresholds

Warning/critical severity bands for `pgfr_analyze.anomaly_report()`, expressed as
fractions of the corresponding `autovacuum_*_freeze_max_age` GUC. Defaults match
the guidance in [postgres-howto #0044](https://postgres.ai/docs/postgres-howtos/performance-optimization/monitoring/how-to-monitor-transaction-id-wraparound-risks);
tune `*_warning_ratio` down on busy clusters where 50% is too late to warn.

| Setting | Default | Description |
|---------|---------|-------------|
| `xid_warning_ratio`   | `0.5` | Warn when `datfrozenxid_age` / `relfrozenxid_age` exceeds this fraction of `autovacuum_freeze_max_age` |
| `xid_critical_ratio`  | `0.8` | Escalate to critical above this fraction |
| `mxid_warning_ratio`  | `0.5` | Warn when `datminmxid_age` / `relminmxid_age` exceeds this fraction of `autovacuum_multixact_freeze_max_age` |
| `mxid_critical_ratio` | `0.8` | Escalate to critical above this fraction |

Tune via:

```sql
insert into pgfr_record.config (key, value) values ('mxid_warning_ratio', '0.25')
    on conflict (key) do update set value = excluded.value;
```

Applies to both database-level (`XID_WRAPAROUND_RISK` / `MXID_WRAPAROUND_RISK`)
and per-table (`TABLE_XID_WRAPAROUND_RISK` / `TABLE_MXID_WRAPAROUND_RISK`) anomalies.
Per-table checks honor each relation's `autovacuum_freeze_max_age` /
`autovacuum_multixact_freeze_max_age` reloption override.

### xmin horizon monitoring

Captures *who* is pinning the xmin horizon (long-running transactions, stale
replication slots, hot-standby-feedback, prepared xacts) so post-hoc forensics
isn't reduced to live-querying four catalogs after the offender has
disconnected. See [postgres-howto on monitoring xmin horizon](https://postgres.ai/docs/postgres-howtos/performance-optimization/monitoring/how-to-monitor-xmin-horizon).

Per-source ages live in typed columns on `pgfr_record.snapshots`
(`activity_xmin_age`, `slot_xmin_age`, `slot_catalog_xmin_age`,
`replication_xmin_age`, `prepared_xmin_age`); the dominant holder's
source-specific details live in `xmin_horizon_detail JSONB`.

Anomalies emitted by `pgfr_analyze.anomaly_report()` (in addition to the
existing `XID_WRAPAROUND_RISK` / `MXID_WRAPAROUND_RISK`):

| Anomaly | Severity | Trigger |
|---------|----------|---------|
| `XMIN_HORIZON_STALL` | `high` / `critical` | `xmin_data_horizon_age > xid_warning_ratio` / `xid_critical_ratio` of `autovacuum_freeze_max_age` (defaults 50% / 80%) |
| `CATALOG_XMIN_HORIZON_STALL` | `high` / `critical` | Same thresholds applied to `slot_catalog_xmin_age` |

Data and catalog fire independently — both can trigger when a logical slot
pins `xmin` and `catalog_xmin` together. Recommendation text is sourced from
`xmin_horizon_detail` and is source-specific: `pg_cancel_backend` first for
active backends, `pg_terminate_backend` for idle-in-txn, `pg_stat_progress_vacuum`
for autovacuum workers, `DROP REPLICATION SLOT` for slots, `ROLLBACK PREPARED`
for prepared xacts. Tie-breaking when multiple sources share the oldest age:
`slot > prepared > activity > replication`.

The `xid_warning_ratio` / `xid_critical_ratio` config keys (already used by
`XID_WRAPAROUND_RISK`) also govern these anomalies — there are no separate
xmin-specific thresholds.

One xmin-specific config key:

| Setting | Default | Description |
|---------|---------|-------------|
| `xmin_capture_query_preview` | `true` | If `false`, the `query_preview` field in `xmin_horizon_detail.holder` is NULL — query text is not stored or transformed. Privacy switch for sensitive deployments. |

Sample queries:

```sql
-- Who's holding the horizon right now?
select * from pgfr_analyze.current_xmin_horizon_holder();

-- Timeline of holders over the last 6 hours:
select * from pgfr_analyze.xmin_horizon_history(now() - interval '6 hours', now());

-- 24-hour horizon-age trend (data + catalog):
select captured_at, xmin_data_horizon_age, slot_catalog_xmin_age, xmin_any_horizon_age
from pgfr_record.snapshots
where captured_at > now() - interval '24 hours'
order by captured_at;
```

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

### Consumption trend engine

Thresholds for `pgfr_analyze.consumption_trend_report()` / `_refresh_consumption_trends()` / `_refresh_consumption_trends_weekly()` -- classifying each basket metric's trend against the database's own baseline. `consumption_trend_min_r2`, `consumption_trend_step_r2_margin`, and `consumption_trend_shape_guard_pct` are generic statistical properties shared by both the 28-day/daily and 84-day/weekly engines; `consumption_trend_min_days` and `consumption_trend_min_weeks` are each engine's own minimum-data gate.

| Setting | Default | Description |
|---------|---------|-------------|
| `consumption_trend_min_days` | `14` | Minimum days of data before the 28-day/daily engine classifies past `insufficient_data` |
| `consumption_trend_min_weeks` | `8` | Minimum weeks of data before the 84-day/weekly engine classifies past `insufficient_data` |
| `consumption_trend_min_r2` | `0.3` | Minimum R² for a line or step model to count as a real fit rather than noise (below this: `stable`) |
| `consumption_trend_step_r2_margin` | `0.15` | Margin by which a step model's R² must beat a line's R² to classify `step` instead of `drift` |
| `consumption_trend_shape_guard_pct` | `25` | Percent shift in a workload-shape indicator, between a window's two fixed halves, that triggers `composition` |

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
| `retention_archive_days` | 7 | 7 | 3 | 3 | 3 |
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
