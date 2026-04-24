# xmin Horizon Monitoring

| Version | Date       | Author       |
|---------|------------|--------------|
| 0.2     | 2026-04-24 | Claude Code  |

Reference: [How to monitor xmin horizon — postgres.ai](https://postgres.ai/docs/postgres-howtos/performance-optimization/monitoring/how-to-monitor-xmin-horizon)

## Changelog

| Version | Changes                                                                                                                                                                                                                                                                                                                                                                                                                    |
|---------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 0.2     | Replace single `xmin_horizon_holders` (JSONB `extra`) with three typed sidecars — `xmin_activity_holders`, `xmin_slot_holders`, `xmin_prepared_holders` — matching the project's existing per-source pattern. Add §8a storage budget and Appendix A worked example. Default `xmin_holders_top_n` 20 → 5. Add `xmin_holders_min_age` collection floor. Clarify that projections are raw rows with no rollup. Drop `pg_prepared_xacts` defensive `undefined_table` wrap. |
| 0.1     | Initial blueprint: aggregate-age columns on `snapshots`, `backend_xmin` on `replication_snapshots`, single JSONB-extra holders sidecar, `XMIN_HORIZON_STALL` + `CATALOG_XMIN_HORIZON_STALL` anomalies, `xmin_horizon_history()` reader, pgTAP tests.                                                                                                                                                                     |

---

## 1. Motivation

pg-flight-recorder already captures `datfrozenxid_age` (database) and `relfrozenxid_age` (per table), and `pgfr_analyze.anomaly_report()` raises `XID_WRAPAROUND_RISK` when either crosses 50% / 80% of `autovacuum_freeze_max_age`. That tells an operator **something is wrong**, but not **why**.

The postgres.ai guide identifies four distinct sources that can pin the xmin horizon and prevent `autovacuum` from freezing tuples:

1. Long-running transaction on the primary — `pg_stat_activity.backend_xmin`
2. Abandoned replication slot — `pg_replication_slots.xmin` and `catalog_xmin`
3. Hot standby feedback — `pg_stat_replication.backend_xmin`
4. Abandoned prepared transaction — `pg_prepared_xacts.transaction`

Any of the four silently stalls cleanup; `datfrozenxid_age` only rises *after* the stall has been in effect long enough to matter. A flight recorder that notices the symptom but forces the operator to live-query four catalogs to find the cause is not finishing the job.

This blueprint specifies additive schema and collection changes to record all four sources at every snapshot, plus reporting additions that attribute a wraparound-risk anomaly to its dominant holder.

---

## 2. Scope and Constraints

- **Additive only.** Per `CLAUDE.md`: add new nullable columns, never remove or rename. Historical rows with `NULL` in the new columns are correct ("not collected then").
- **Compatible with PG 15 / 16 / 17 / 18.** All four source views exist on every supported version. No version-branching required.
- **No new pg_cron job.** Collection piggybacks on the existing `pgfr_record.snapshot()` cadence (60 s default).
- **Self-isolating.** Each new section in `snapshot()` lives in its own `BEGIN / EXCEPTION WHEN OTHERS / RAISE WARNING` block, matching every other collection section.
- **Primary-only emission.** All four catalogs exist on standbys but `pg_stat_replication` is empty there; the collector runs unchanged, standby rows simply have NULL for source (3).

---

## 3. Captured Sources (Reference Query)

Adapted from the postgres.ai guide. The per-source CTE becomes the collection query; the aggregated `greatest(...)` values become two precomputed columns on `snapshots`.

```sql
with bits as (
  select
    (select backend_xmin from pg_stat_activity
      where backend_xmin is not null
        and pid <> pg_backend_pid()
      order by age(backend_xmin) desc limit 1
    ) as activity_xmin,
    (select xmin from pg_replication_slots
      where xmin is not null
      order by age(xmin) desc limit 1
    ) as slot_xmin,
    (select catalog_xmin from pg_replication_slots
      where catalog_xmin is not null
      order by age(catalog_xmin) desc limit 1
    ) as slot_catalog_xmin,
    (select backend_xmin from pg_stat_replication
      where backend_xmin is not null
      order by age(backend_xmin) desc limit 1
    ) as replication_xmin,
    (select transaction from pg_prepared_xacts
      order by age(transaction) desc limit 1
    ) as prepared_xid
)
select
  *,
  age(activity_xmin)     as activity_xmin_age,
  age(slot_xmin)         as slot_xmin_age,
  age(slot_catalog_xmin) as slot_catalog_xmin_age,
  age(replication_xmin)  as replication_xmin_age,
  age(prepared_xid)      as prepared_xid_age,
  greatest(
    age(activity_xmin),
    age(slot_xmin),
    age(replication_xmin),
    age(prepared_xid)
  ) as xmin_data_horizon_age,
  age(slot_catalog_xmin) as xmin_catalog_slot_age,
  greatest(
    age(activity_xmin),
    age(slot_xmin),
    age(replication_xmin),
    age(prepared_xid),
    age(slot_catalog_xmin)
  ) as xmin_any_horizon_age
from bits;
```

Three aggregate columns are deliberately distinct:

- `xmin_data_horizon_age` — oldest xmin pinning user-table cleanup (the four data sources). This is what blocks `autovacuum` from freezing tuples in user tables.
- `xmin_catalog_slot_age` — only `greatest(catalog_xmin)` across replication slots. This is what blocks cleanup of system catalogs for logical decoding. A logical slot can elevate this while leaving `xmin_data_horizon_age` untouched, or vice versa.
- `xmin_any_horizon_age` — `greatest` of the above two. Useful as a single "anything pinning xmin" metric.

Previous versions conflated catalog and data semantics by mixing data sources into a `catalog_horizon_age`. That was wrong: an ordinary long-running transaction pins the data horizon, not the catalog horizon.

---

## 4. Schema Changes

### 4.1 `pgfr_record.snapshots` — new columns

Add to `pgfr_record/sql/02_tables_legacy.sql` (via `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` in a `DO $$ BEGIN ... END $$` block, matching the existing delta-column pattern):

| Column                            | Type     | Source                                              |
|-----------------------------------|----------|-----------------------------------------------------|
| `activity_xmin`                   | `xid`    | `pg_stat_activity.backend_xmin` (oldest, self-excluded) |
| `activity_xmin_age`               | `bigint` | `age()` of above                                    |
| `slot_xmin`                       | `xid`    | `pg_replication_slots.xmin` (oldest)                |
| `slot_xmin_age`                   | `bigint` | `age()` of above                                    |
| `slot_catalog_xmin`               | `xid`    | `pg_replication_slots.catalog_xmin` (oldest)        |
| `slot_catalog_xmin_age`           | `bigint` | `age()` of above                                    |
| `replication_xmin`                | `xid`    | `pg_stat_replication.backend_xmin` (oldest, physical walsenders only) |
| `replication_xmin_age`            | `bigint` | `age()` of above                                    |
| `prepared_xid`                    | `xid`    | `pg_prepared_xacts.transaction` (oldest)            |
| `prepared_xid_age`                | `bigint` | `age()` of above                                    |
| `xmin_data_horizon_age`           | `bigint` | `greatest` of the four data-source ages             |
| `xmin_catalog_slot_age`           | `bigint` | alias for `slot_catalog_xmin_age` (kept for anomaly clarity) |
| `xmin_any_horizon_age`            | `bigint` | `greatest(xmin_data_horizon_age, xmin_catalog_slot_age)` |
| `xmin_holders_collection_status`  | `text`   | `collected` / `below_floor` / `collector_failed` / `not_available` |
| `xmin_holders_truncated_count`    | `integer`| sum across sources of `(actual_holders - top_n)` when positive, else 0; NULL when status ≠ `collected` |

Storing raw `xid` *and* `bigint` age keeps fidelity (xid is 32-bit circular) while making ORDER BY / threshold comparisons trivial. **Never order raw `xid` values directly to determine oldest/newest — use `age(xid)` captured at snapshot time.**

`xmin_holders_collection_status` lets downstream readers distinguish "horizon healthy, nothing to record" from "horizon stalled but collector failed" from "below configured floor". Without it, an empty holder sidecar is ambiguous. `xmin_holders_truncated_count` flags pile-ups that exceeded `xmin_holders_top_n` so the operator knows the sidecar view is a sample, not a census.

### 4.2 `pgfr_record.replication_snapshots` — new columns

| Column                 | Type      | Source                                                                 |
|------------------------|-----------|------------------------------------------------------------------------|
| `backend_xmin`         | `xid`     | `pg_stat_replication.backend_xmin`                                     |
| `backend_xmin_age`     | `bigint`  | `age(backend_xmin)`                                                    |
| `slot_name`            | `text`    | `pg_replication_slots.slot_name` joined via `active_pid = pid`         |
| `is_logical_walsender` | `boolean` | true when the joined slot has `slot_type = 'logical'`                  |

`slot_name` / `is_logical_walsender` matter for anomaly attribution: a logical walsender appears in `pg_stat_replication` too, but the actionable remediation is against its slot (look at subscriber lag / drop-or-advance the slot), not against `hot_standby_feedback` on a standby. The anomaly filter excludes rows with `is_logical_walsender = true` when attributing the `replication` source — those holders are already covered by `xmin_slot_holders`.

### 4.3 Per-source holder sidecar tables

The oldest-xmin per source (§4.1) answers "how bad is it"; the operator still needs to know *which* backend / slot / prepared xact / standby to act on. Per `CLAUDE.md`'s schema philosophy ("Strong typing catches errors early ... Schema-as-documentation"), each source gets its own typed sidecar, mirroring the existing pattern (`replication_snapshots`, `vacuum_progress_snapshots`).

All three tables are capped at `xmin_holders_top_n` rows per snapshot per source (configurable via `pgfr_record._get_config('xmin_holders_top_n', '5')`, default **5**). Five is enough to identify a pile-up without hoarding rows: the oldest holder is the actionable one, and four more provide attribution context when multiple sessions / slots lag together. Rows with NULL xmin are not emitted.

**Collection floor** (storage mitigation): holders are only written when `data_horizon_age > xmin_holders_min_age` (configurable, default `1,000,000` xids, ~2 min at modest TPS). Below the floor nothing is holding the horizon long enough to matter, so the sidecars stay empty and healthy systems pay only the 12-bigint cost on `snapshots`. The aggregate-age columns on `snapshots` are always captured regardless of the floor — they're cheap and always useful for trend plots.

**Partitioning** (see §4.3.5 for details): all three tables are daily `RANGE`-partitioned by `sample_ts int4` using the existing Phase 3 infrastructure. Retention is governed by `retention_snapshots_days` (default 30). No new GC code.

#### 4.3.1 `pgfr_record.xmin_activity_holders`

From `pg_stat_activity` where `backend_xmin IS NOT NULL`. This is the `pg_terminate_backend` target set.

```sql
CREATE TABLE IF NOT EXISTS pgfr_record.xmin_activity_holders (
    sample_ts         INTEGER NOT NULL,            -- partition key; see §4.3.5
    snapshot_id       INTEGER NOT NULL,
    pid               INTEGER NOT NULL,
    leader_pid        INTEGER,                     -- non-null = parallel worker; terminate the leader, not this pid
    datid             OID,
    datname           TEXT,
    usesysid          OID,                         -- stable identity (usename can be renamed)
    usename           TEXT,
    application_name  TEXT,
    client_addr       INET,
    backend_type      TEXT,
    state             TEXT,                        -- 'active' | 'idle in transaction' | 'idle in transaction (aborted)' | ...
    backend_start     TIMESTAMPTZ,
    xact_start        TIMESTAMPTZ,
    xact_age_seconds  BIGINT,                      -- extract(epoch from now() - xact_start); context for idle-in-txn detection
    query_start       TIMESTAMPTZ,
    query_age_seconds BIGINT,                      -- extract(epoch from now() - query_start)
    state_change      TIMESTAMPTZ,
    wait_event_type   TEXT,
    wait_event        TEXT,
    backend_xid       XID,                         -- current write xid (may be NULL while backend_xmin is set — read-only txn with snapshot)
    backend_xid_age   BIGINT,
    backend_xmin      XID NOT NULL,                -- the horizon holder — sidecar rows only emitted when non-null
    backend_xmin_age  BIGINT NOT NULL,
    queryid           BIGINT,                      -- PG14+; joins to statement_snapshots
    query_preview     TEXT,                        -- left(query, track_activity_query_size); CR/LF/tabs stripped
    PRIMARY KEY (sample_ts, snapshot_id, pid)
);
CREATE INDEX IF NOT EXISTS xmin_activity_holders_age_idx
    ON pgfr_record.xmin_activity_holders(backend_xmin_age DESC);
COMMENT ON TABLE pgfr_record.xmin_activity_holders IS
  'Backends holding the xmin horizon via pg_stat_activity.backend_xmin. '
  'Top xmin_holders_top_n per snapshot, ordered by age(backend_xmin) DESC. '
  'Self-pin excluded via pid <> pg_backend_pid(); autovacuum workers excluded.';
```

Column notes:

- `leader_pid`: when populated, the holder is a parallel worker. Terminating the worker accomplishes nothing — the leader respawns it. Anomaly recommendations name the leader when this is non-null.
- `datid` / `datname`: `pg_stat_activity` is cluster-wide; knowing the database focuses remediation and joins cleanly to `pg_stat_database` exports.
- `backend_xid` / `backend_xid_age`: context-only. `backend_xmin` is the true horizon holder signal; `backend_xid` tells you whether the xact has written anything yet.
- `xact_age_seconds` / `query_age_seconds`: surfaces long idle-in-transaction and long-running queries that are suspicious even when `backend_xmin` status varies. Documented caveat: a long `xact_start` without `backend_xmin` means the backend currently holds no snapshot, so it is not pinning the horizon *right now* — but it is a strong signal the backend is misbehaving.
- `query_preview` cap: `left(query, current_setting('track_activity_query_size')::int)` (default 1024), with CR/LF/tabs stripped for grep-ability. Can be fully suppressed via `xmin_capture_query_preview = false` for privacy-sensitive deployments.

#### 4.3.2 `pgfr_record.xmin_slot_holders`

From `pg_replication_slots` where `xmin IS NOT NULL OR catalog_xmin IS NOT NULL`. Both xmins stored on one row — separate `xmin` (data) and `catalog_xmin` (system catalogs) because a logical slot can hold either or both at different ages.

```sql
CREATE TABLE IF NOT EXISTS pgfr_record.xmin_slot_holders (
    sample_ts            INTEGER NOT NULL,         -- partition key; see §4.3.5
    snapshot_id          INTEGER NOT NULL,
    slot_name            TEXT NOT NULL,
    slot_type            TEXT,                     -- 'physical' | 'logical'
    database             TEXT,                     -- logical slots only
    plugin               TEXT,                     -- logical slots only
    active               BOOLEAN,
    active_pid           INTEGER,
    xmin                 XID,
    xmin_age             BIGINT,
    catalog_xmin         XID,
    catalog_xmin_age     BIGINT,
    restart_lsn          PG_LSN,
    confirmed_flush_lsn  PG_LSN,
    wal_status           TEXT,                     -- PG13+: 'reserved' | 'extended' | 'unreserved' | 'lost'
    safe_wal_size        BIGINT,                   -- PG13+
    conflicting          BOOLEAN,                  -- PG16+: slot has a conflict with recovery
    invalidation_reason  TEXT,                     -- PG17+: 'wal_removed' | 'horizon' | 'wal_level' | ...
    PRIMARY KEY (sample_ts, snapshot_id, slot_name)
);
COMMENT ON TABLE pgfr_record.xmin_slot_holders IS
  'Replication slots holding the xmin horizon (physical slots via xmin, '
  'logical slots via xmin and/or catalog_xmin). DROP REPLICATION SLOT target set. '
  'conflicting / invalidation_reason populated conditionally on PG version.';
```

`conflicting` (PG16+) and `invalidation_reason` (PG17+) are exactly the columns that distinguish "slot is lagging" (remediation: help it catch up) from "slot is invalidated" (remediation: drop it — it's already dead). Populated conditionally via `_pg_version()` guard in the collector; NULL on older versions is correct ("not available").

#### 4.3.3 `pgfr_record.xmin_prepared_holders`

From `pg_prepared_xacts`. This is the `ROLLBACK PREPARED` target set.

```sql
CREATE TABLE IF NOT EXISTS pgfr_record.xmin_prepared_holders (
    sample_ts        INTEGER NOT NULL,              -- partition key; see §4.3.5
    snapshot_id      INTEGER NOT NULL,
    gid              TEXT NOT NULL,                 -- ROLLBACK PREPARED target
    prepared_xid     XID,
    prepared_xid_age BIGINT,
    prepared_at      TIMESTAMPTZ,
    owner            TEXT,
    database         TEXT,
    PRIMARY KEY (sample_ts, snapshot_id, gid)
);
COMMENT ON TABLE pgfr_record.xmin_prepared_holders IS
  'Prepared transactions holding the xmin horizon. ROLLBACK PREPARED target set.';
```

#### 4.3.4 Source `replication` — no new table

Covered by the additions to `replication_snapshots` (§4.2): `backend_xmin`, `backend_xmin_age`, `slot_name`, `is_logical_walsender`. Each row already carries `pid`, `application_name` (the **standby's identity** for physical walsenders — `hot_standby_feedback` is configured on the standby, so `application_name` is *the* key field for remediation), `client_addr`, `usename`, `state`, `sync_state`. Logical walsenders are filtered out during anomaly attribution (see §6.1) because their actionable data lives in `xmin_slot_holders` instead.

#### 4.3.5 Partitioning and primary keys

Postgres requires every unique / primary-key constraint on a RANGE-partitioned table to include the partition key. The three sidecars declare `sample_ts INTEGER` first in each PK:

- `xmin_activity_holders`: `PRIMARY KEY (sample_ts, snapshot_id, pid)`
- `xmin_slot_holders`: `PRIMARY KEY (sample_ts, snapshot_id, slot_name)`
- `xmin_prepared_holders`: `PRIMARY KEY (sample_ts, snapshot_id, gid)`

`sample_ts` is computed from `now()` against the fixed installation epoch defined in `pgfr_record/sql/06_partition_infra.sql` (the `pgfr_record.epoch()` helper).

`_ensure_partition()` in `06_partition_infra.sql` takes an index-override parameter for non-default column layouts (the `09_phase3_snapshots_v2.sql` tables already use this — e.g. `_ensure_partition('replication_snapshots_v2', current_date, 'pid, sample_ts desc')`). The holder tables call it with:

- activity: `'backend_xmin_age desc, sample_ts desc'`
- slot: `'slot_name, sample_ts desc'`
- prepared: `'gid, sample_ts desc'`

Daily partition creation and GC piggyback on the existing Phase 3 cron jobs (`pgfr-ensure-partitions`, `pgfr-truncate-old-partitions`, `pgfr-drop-ancient-partitions`). FK to `snapshots(id)` is dropped from the sidecar PKs because FKs across partition boundaries are awkward and the `_ensure_partition` pattern already forgoes them for `replication_snapshots_v2`.

---

## 5. Collection (`pgfr_record.snapshot()`)

A new section is inserted in `pgfr_record/sql/04b_functions_snapshot.sql` after the existing replication stats block and before the table-stats block. It runs:

1. Four aggregate queries matching the CTE in §3, writing into the new `snapshots` columns.
2. An extended `pg_stat_replication` read that also captures `backend_xmin` into `replication_snapshots` (covers source `replication`).
3. Top-N INSERT from `pg_stat_activity` into `xmin_activity_holders` (filtered `backend_xmin IS NOT NULL`, ordered by `age(backend_xmin) DESC`).
4. INSERT from `pg_replication_slots` into `xmin_slot_holders` (filtered `xmin IS NOT NULL OR catalog_xmin IS NOT NULL`).
5. INSERT from `pg_prepared_xacts` into `xmin_prepared_holders`.

Each step lives under its own `BEGIN / EXCEPTION WHEN OTHERS` with `RAISE WARNING` — failure of one source does not abort others, matching the existing sparse-collector isolation pattern. Inner guards:

- `pg_stat_replication.backend_xmin` has existed since 9.4; no version branch.
- Section uses `_set_section_timeout()` (250 ms default) like every other section.

Cost is small: four aggregates over catalogs whose typical cardinality is 10–100 rows, holding `AccessShareLock` only.

---

## 6. Analysis (`pgfr_analyze`)

### 6.1 Two new anomalies in `anomaly_report()`

Added to `pgfr_analyze/sql/01_core_metrics.sql` **before** the existing `XID_WRAPAROUND_RISK` check so that cause precedes symptom in the report. Each anomaly's `metric_value` and `recommendation` read the *typed* columns of the appropriate sidecar for the dominant holder at the latest snapshot.

- `XMIN_HORIZON_STALL` — fires when `data_horizon_age` > 50% of `autovacuum_freeze_max_age` (critical at 80%). Source attribution selects the oldest holder across the four sidecar sources, then emits a source-specific recommendation:
  - **activity** (from `xmin_activity_holders`): `"terminate PID %s (user=%s, app=%s, state=%s, xact_start=%s, query: %s)"` — uses `pid`, `usename`, `application_name`, `state`, `xact_start`, `query_preview`.
  - **slot** (from `xmin_slot_holders`): `"DROP REPLICATION SLOT %s (type=%s, active=%s, restart_lsn=%s)"` — uses `slot_name`, `slot_type`, `active`, `restart_lsn`.
  - **replication** (from `replication_snapshots`): `"review hot_standby_feedback on standby '%s' (addr=%s, pid=%s, sync_state=%s)"` — uses `application_name`, `client_addr`, `pid`, `sync_state`. Emphasises `application_name` because `hot_standby_feedback` is set on the standby; that field is how the operator identifies which standby's config to change.
  - **prepared** (from `xmin_prepared_holders`): `"ROLLBACK PREPARED '%s' (owner=%s, database=%s, prepared_at=%s)"` — uses `gid`, `owner`, `database`, `prepared_at`.
- `CATALOG_XMIN_HORIZON_STALL` — fires when only `catalog_horizon_age` is elevated (logical-replication catalog cleanup stall). Always points at `xmin_slot_holders` rows with `slot_type = 'logical'` and non-null `catalog_xmin`.

Both anomalies skip when their source columns are NULL (historical snapshots from before this change land).

### 6.2 New reader: `pgfr_analyze.xmin_horizon_history(p_start, p_end)`

`UNION ALL`s the three holder sidecars and the `backend_xmin` column on `replication_snapshots`, joined to `snapshots`, projecting to a uniform shape so forensics can see every horizon holder over a window in one scroll:

```sql
RETURNS TABLE (
    captured_at       TIMESTAMPTZ,
    data_horizon_age  BIGINT,
    catalog_horizon_age BIGINT,
    source            TEXT,     -- 'activity' | 'slot' | 'replication' | 'prepared'
    xmin_age          BIGINT,
    holder_key        TEXT,     -- pid / slot_name / application_name / gid
    holder_detail     TEXT      -- human-readable summary of source-specific cols
)
```

The `holder_detail` string is formatted per source (e.g. activity: `"app=%s user=%s state=%s query=%s"`). Operators who want structured columns query the sidecar tables directly. Analogous to `what_happened_at` and `incident_timeline`.

---

## 7. Tests

### 7.1 pgTAP: `pgfr_record/tests/16_xmin_horizon.sql`

- Column existence on `snapshots` (12 columns), `replication_snapshots` (2 columns).
- Table existence for `xmin_activity_holders`, `xmin_slot_holders`, `xmin_prepared_holders`, with column-existence checks on `pid`, `application_name`, `queryid`, `query_preview` (activity); `slot_name`, `slot_type`, `catalog_xmin` (slot); `gid`, `prepared_at` (prepared).
- `snapshot()` populates `data_horizon_age` and `catalog_horizon_age` as non-negative.
- Simulated long-running transaction: open a second connection with `BEGIN; SELECT txid_current(); SELECT pg_sleep(2);`, call `snapshot()`, assert the calling backend's pid + `backend_xmin` appears in `xmin_activity_holders` with the expected `application_name`.
- Invariant: `data_horizon_age >= greatest(data_xmin_activity_age, data_xmin_slot_age, data_xmin_replication_age, data_xmin_prepared_age)`.
- Invariant: `catalog_horizon_age >= data_horizon_age`.

### 7.2 pgTAP: `pgfr_analyze/tests/test_xmin_horizon.sql`

- Fresh DB does not fire either anomaly (analogous to existing `10_xid_wraparound.sql` fresh-DB assertion).
- Synthetic stall: `UPDATE pgfr_record.snapshots SET data_horizon_age = (SELECT setting::bigint * 0.6 FROM pg_settings WHERE name = 'autovacuum_freeze_max_age') WHERE id = (SELECT max(id) FROM pgfr_record.snapshots)` — assert `XMIN_HORIZON_STALL` fires at severity `high`; raise to 0.9 and assert `critical`.
- `xmin_horizon_history()` returns rows matching the synthetic fixture.

---

## 8. Docs

- `pgfr_record/README.md` — add an entry to the captured-metrics table covering the four xmin sources.
- `REFERENCE.md` — new section "xmin Horizon" documenting:
  - the twelve new columns on `snapshots`
  - `replication_snapshots.backend_xmin` + `backend_xmin_age`
  - the three holder sidecars (`xmin_activity_holders`, `xmin_slot_holders`, `xmin_prepared_holders`) with full column lists
  - `xmin_holders_top_n` config key
  - the two new anomalies and their source-specific remediations
  - the `xmin_horizon_history()` reader
- `CLAUDE.md` — unchanged (the additive-only guidance already covers this change).

---

## 8a. Storage budget

Holder rows are **raw, per-snapshot, no rollup** — same retention model as `statement_snapshots` / `table_snapshots` / `replication_snapshots`. Daily RANGE-partitioned via the existing Phase 3 infrastructure; GC'd by `retention_snapshots_days` (default 30). There is no aggregated / summarised variant (the existing `wait_event_aggregates` / `lock_aggregates` / `activity_aggregates` rollups don't apply — for horizon holders the identity of *which* backend / slot / xact held the xmin is the whole point, and cannot be summarised).

Row widths (typical, Postgres overhead included):

| Table                               | Bytes/row             |
|-------------------------------------|-----------------------|
| `xmin_activity_holders`             | ~700 B (query_preview dominates) |
| `xmin_slot_holders`                 | ~180 B                |
| `xmin_prepared_holders`             | ~120 B                |
| `replication_snapshots` (added)     | +12 B                 |
| `snapshots` (added)                 | +60 B                 |

Rows per snapshot at 60-second cadence:

| Scenario                          | activity | slot | prepared | Notes |
|-----------------------------------|----------|------|----------|-------|
| Healthy (no held xmins)           | 0–3      | 0–5  | 0        | Most backends are `idle` with `backend_xmin = NULL`; slot count = number of configured replication slots; typical app does not use 2PC. |
| Sustained single holder           | 1        | 0–5  | 0        | One long-running txn / idle-in-txn session — the common failure mode. |
| Top-N cap saturated (upper bound) | 5        | 5    | 1        | 5 concurrent backends each with a distinct `backend_xmin` (e.g. a reporting fleet); 5 logical slots lagging (fan-out publisher); plus a stuck prepared xact. Used here as a conservative sizing ceiling — real systems almost never hit this. |

30-day **raw storage** projections (no rollup; all rows retained at snapshot cadence):

| Scenario                    | Per day | 30 days raw |
|-----------------------------|---------|-------------|
| Healthy                     | ~4 MB   | ~120 MB     |
| Sustained single holder     | ~8 MB   | ~240 MB     |
| Top-N cap saturated (ceiling)| ~11 MB | ~325 MB     |

**With the collection floor** (`xmin_holders_min_age = 1,000,000`): healthy systems write zero holder rows — raw storage is bounded by the twelve tiny bigints on `snapshots` (`~60 B × 1440 × 30 ≈ 2.6 MB/month`). Cost scales with how long and how badly the horizon stalls, which is exactly when forensics matters.

Reference point: `statement_snapshots` baseline is ~960 MiB/30d raw at `top_n=50` (SPEC.md §9.2). Worst-case holders are ~1/3 of that; typical is far below.

---

## 9. Rollout

Because every change is additive and idempotent (`ADD COLUMN IF NOT EXISTS`, `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`), the standard upgrade path in the project README applies:

```bash
psql --single-transaction -f pgfr_record/install.sql
psql --single-transaction -f pgfr_analyze/install.sql
```

No migration script, no dual-write period, no config changes required. Historical rows remain NULL in the new columns; analysis functions treat NULL as "not collected" and suppress the new anomalies on those rows.

---

## 10. Tradeoffs

- **Top-N per source vs. oldest-only.** The postgres.ai query picks one row per source. For forensics a flight recorder wants the pile-up, not just the winner — a fleet of idle-in-transaction sessions all pinning similar xmins is a common failure mode and the single oldest tells you nothing about the pattern. Cost is bounded by `xmin_holders_top_n` (default 5): enough to reveal pile-ups, small enough that worst-case 30-day raw storage stays at ~325 MB.
- **Three typed tables vs. one `JSONB` holders table.** Per-source tables carry only the columns that apply, `\d pgfr_record.xmin_activity_holders` documents itself, and queries filter/sort on typed columns (`xact_start`, `restart_lsn`, `prepared_at`) without JSON extraction. Follows the project's existing sidecar pattern (`replication_snapshots`, `vacuum_progress_snapshots`). Cost: three tables to create and GC, not one.
- **Collection floor vs. always-collect.** The floor trades worst-case storage (~325 MB/30d raw) for a small blind spot: bursts where xmin is briefly held below the threshold are not recorded. The aggregate ages on `snapshots` still capture the *shape* of those bursts, only the per-holder attribution is missing. The floor is a config knob; operators who want everything-always set `xmin_holders_min_age = 0`.
- **`xid` vs. `bigint` storage.** Storing both is mildly redundant but matches the source fidelity (`xid`) and the natural threshold/sort key (`bigint age`). Query analysis defaults to the age column.
- **Precomputed `*_horizon_age` columns.** The two `greatest(...)` columns could be a view, but precomputing at write time (a) keeps analysis queries simple, (b) survives export via `pg_dump`, and (c) costs negligible bytes.
- **Standby collection.** The standby writes rows where `data_xmin_replication` is always NULL (because `pg_stat_replication` is empty there). Accepted — the recorder should still record the three other sources on standbys.

---

## 11. Non-goals

- No alerting integration. The anomalies populate `anomaly_report()`; shipping them to PagerDuty / Slack is outside the extension's scope.
- No automatic remediation. The `recommendation` column is advisory; the operator still issues the `pg_terminate_backend` / `DROP SLOT` / `ROLLBACK PREPARED`.
- No xid-freeze-progress tracking over time beyond what `datfrozenxid_age` already provides. That would require parsing `autovacuum` logs, which is out of scope (see the guide's log-based monitoring section for manual inspection).

---

## Appendix A. Example snapshot content

Scenario: a `BEGIN;` session (PID 48291) has been idle-in-transaction for 3 minutes; a second session is executing a long report. A physical replica `replica_west` has `hot_standby_feedback=on`. No logical slots, no prepared xacts. Snapshot taken at `2026-04-24 14:32:00+00`.

`pgfr_record.snapshots` — new columns only:

```text
id                        | 12345
captured_at               | 2026-04-24 14:32:00+00
data_xmin_activity        | 789001234
data_xmin_activity_age    | 450000
data_xmin_slot            | (null)
data_xmin_slot_age        | (null)
catalog_xmin_slot         | (null)
catalog_xmin_slot_age     | (null)
data_xmin_replication     | 789050000
data_xmin_replication_age | 400000
data_xmin_prepared        | (null)
data_xmin_prepared_age    | (null)
data_horizon_age          | 450000
catalog_horizon_age       | 450000
```

`pgfr_record.xmin_activity_holders`:

```text
snapshot_id | pid   | backend_xmin | backend_xmin_age | usename | application_name | client_addr | state               | xact_start             | query_preview
------------+-------+--------------+------------------+---------+------------------+-------------+---------------------+------------------------+-----------------------------------------
12345       | 48291 | 789001234    | 450000           | app_rw  | orders_worker    | 10.0.1.42   | idle in transaction | 2026-04-24 14:29:00+00 | BEGIN
12345       | 48299 | 789020000    | 430000           | reports | report_batch     | 10.0.1.45   | active              | 2026-04-24 14:30:00+00 | SELECT sum(amount) FROM large_ledger...
```

`pgfr_record.replication_snapshots` — existing row, new columns highlighted:

```text
snapshot_id | pid | application_name | client_addr | state     | sync_state | backend_xmin | backend_xmin_age
------------+-----+------------------+-------------+-----------+------------+--------------+------------------
12345       | 301 | replica_west     | 10.0.2.7    | streaming | async      | 789050000    | 400000
```

`xmin_slot_holders`, `xmin_prepared_holders`: empty in this scenario.

`anomaly_report()` would emit (once the stall crosses the 50% threshold — shown here for shape):

```text
anomaly_type   | XMIN_HORIZON_STALL
severity       | high
description    | xmin horizon stalled by 'activity' source
metric_value   | data_horizon_age=100,450,000 (50.2% of autovacuum_freeze_max_age); dominant: activity
threshold      | data_horizon_age > 100,000,000 (50% of 200,000,000)
recommendation | terminate PID 48291 (user=app_rw, app=orders_worker,
                 state=idle in transaction, xact_start=2026-04-24 14:29:00+00, query: BEGIN)
```
