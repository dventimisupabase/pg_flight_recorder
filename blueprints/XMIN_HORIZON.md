# xmin Horizon Monitoring

| Version | Date       | Author       |
|---------|------------|--------------|
| 0.3     | 2026-04-24 | Claude Code  |

Reference: [How to monitor xmin horizon — postgres.ai](https://postgres.ai/docs/postgres-howtos/performance-optimization/monitoring/how-to-monitor-xmin-horizon)

## Changelog

| Version | Changes                                                                                                                                                                                                                                                                                                                                                                                                                    |
|---------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 0.3     | Three-reviewer pass. **Correctness**: split `catalog_horizon_age` into `xmin_catalog_slot_age` (slot-only) vs `xmin_any_horizon_age` (union) — previous definition mixed data sources into a "catalog" metric, which was semantically wrong. Floor gate now per-sidecar: slot sidecar gates on `greatest(data, catalog)` so catalog-only stalls are attributable. Collector self-pin excluded via `pid <> pg_backend_pid()`. Single-pass per source (write sidecar first, derive aggregate) eliminates the read-vs-read race. `CATALOG_XMIN_HORIZON_STALL` fires independently of data anomalies (not XOR). Partitioning PK includes `sample_ts` as required by RANGE partition key. **Attribution**: activity holders gain `leader_pid` (parallel worker remediation), `datname`, `usesysid`, `backend_xid`, `xact_age_seconds`, `query_age_seconds`. Slot holders gain `conflicting` (PG16+) and `invalidation_reason` (PG17+). Replication rows gain `slot_name` + `is_logical_walsender`; logical walsenders filtered out of `replication` source attribution (routed via slot sidecar — hot_standby_feedback advice is wrong for them). `xmin_holders_collection_status` + `xmin_holders_truncated_count` disambiguate empty sidecars. Attribution fallback when sidecar row absent. **Naming**: rename to `activity_xmin`, `slot_xmin`, `slot_catalog_xmin`, `replication_xmin`, `prepared_xid`, `xmin_data_horizon_age`, `xmin_catalog_slot_age`, `xmin_any_horizon_age`. **Thresholds**: new `XMIN_HORIZON_STALL_WARNING` at `xmin_stall_warning_age` (absolute, default 50M xids) so early onset is flagged before wraparound-risk territory. **Tests**: red/green/refactor TDD workflow explicit. Two-session RR fixture replaces flaky `txid_current() + pg_sleep`. Self-pin exclusion, catalog-only gate, truncation count, parallel-worker, attribution-fallback, and independent catalog-anomaly tests all called out. Integration tests (HSF) split from unit tests. **Misc**: `query_preview` sized to `track_activity_query_size`, CR/LF stripped, suppressible via `xmin_capture_query_preview`. Appendix A numbers now internally consistent (~100.5M, crosses 50% of 200M default). `xid` ordering caveat documented. Materialization-vs-view rationale added to tradeoffs. |
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

**Collection floor** (storage mitigation), per-sidecar:

- `xmin_slot_holders` writes when `greatest(xmin_data_horizon_age, xmin_catalog_slot_age) > xmin_holders_min_age` — logical slots can pin `catalog_xmin` alone (data horizon untouched) and that's precisely what `CATALOG_XMIN_HORIZON_STALL` needs to attribute. Previous versions gated all three sidecars on data-horizon-only, which emptied the slot sidecar exactly when it was most needed.
- `xmin_activity_holders`, `xmin_prepared_holders`, and the `replication_snapshots` xmin columns write when `xmin_data_horizon_age > xmin_holders_min_age`. Catalog-only stalls don't come from these sources.

`xmin_holders_min_age` is configurable, default `1,000,000` xids (~2 min at modest TPS). Below the floor, no holders are written; the aggregate-age columns on `snapshots` are still captured (they're cheap and always useful for trend plots) and `xmin_holders_collection_status` is set to `below_floor` so downstream readers don't confuse "floor gate" with "collector failed" or "nothing to record". Collector failures are already captured by the existing `collection_stats` / `_record_collection_end` infrastructure in `pgfr_record/sql/03_functions_util.sql`; the status column sets `collector_failed` when the error path fires.

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

A new section is inserted in `pgfr_record/sql/04b_functions_snapshot.sql` after the existing replication stats block and before the table-stats block. Single-pass per source: **write top-N into the sidecar first, then derive the aggregate for `snapshots` from the sidecar** (`max(age)` / `min(xmin)`). This eliminates the race between two successive reads of the same catalog and makes aggregate and sidecar always internally consistent.

1. Extended `pg_stat_replication` read — captures `backend_xmin`, `backend_xmin_age`, `slot_name` (via `LEFT JOIN pg_replication_slots s ON s.active_pid = r.pid`), and `is_logical_walsender = (s.slot_type = 'logical')` into `replication_snapshots`. Aggregate `replication_xmin` / `replication_xmin_age` on `snapshots` is derived from rows with `is_logical_walsender IS NOT TRUE` (logical walsenders are attributed via the slot sidecar; see §6.1).
2. `xmin_activity_holders` — top-N INSERT from `pg_stat_activity` filtered by:

   ```sql
   WHERE backend_xmin IS NOT NULL
     AND pid <> pg_backend_pid()
     AND backend_type NOT IN ('autovacuum launcher','autovacuum worker')
   ORDER BY age(backend_xmin) DESC
   LIMIT xmin_holders_top_n
   ```

   `pid <> pg_backend_pid()` is essential: `snapshot()` itself runs in a transaction and would otherwise self-pin every snapshot. Autovacuum worker xmins are filtered because they're transient (held briefly during vacuum work) and not actionable by an operator. A second query counts the excess (`actual_holders - top_n`) for `xmin_holders_truncated_count`. `activity_xmin` / `activity_xmin_age` on `snapshots` are derived from the sidecar's `max(backend_xmin_age)`.
3. `xmin_slot_holders` — INSERT from `pg_replication_slots` where `xmin IS NOT NULL OR catalog_xmin IS NOT NULL`. `conflicting` and `invalidation_reason` populated conditionally on `_pg_version() >= 16` / `>= 17`. Aggregates `slot_xmin_age` and `slot_catalog_xmin_age` derived from the sidecar.
4. `xmin_prepared_holders` — INSERT from `pg_prepared_xacts`. `prepared_xid_age` aggregate derived from the sidecar.

Each step lives under its own `BEGIN / EXCEPTION WHEN OTHERS` with `RAISE WARNING` — failure of one source does not abort others, matching the existing sparse-collector isolation pattern. On failure of any step, `xmin_holders_collection_status` is set to `collector_failed` and the existing `_record_collection_end()` path logs `SQLERRM` to `collection_stats.error_message`.

`_set_section_timeout()` (250 ms default) guards each step as with every other section. Cost is small: four catalog reads with `AccessShareLock` only.

**Behavior on standbys.** Previous versions summarised this as "source (3) is always NULL on standbys." That oversimplifies:

- `pg_stat_activity.backend_xmin` — populated on standbys too. Read-only backends with `hot_standby_feedback = on` round-trip xmin back to the primary, and long read queries on the standby itself show up here. `xmin_activity_holders` is useful on both roles.
- `pg_replication_slots` — populated when the standby has cascading replication slots. `xmin_slot_holders` is useful on both roles.
- `pg_stat_replication` — empty on a standby that has no cascading downstream replicas; populated when it does. `replication_xmin` on `snapshots` is therefore NULL on most standbys, non-NULL on cascading ones.
- `pg_prepared_xacts` — rows visible on a standby reflect prepared xacts from the primary. They do *not* pin the standby's xmin horizon in the same sense; the primary's horizon is what controls cleanup. `xmin_prepared_holders` is written but the analyzer's `XMIN_HORIZON_STALL` anomaly on a standby is primarily informational.

The collector runs unchanged on standbys; all four source reads use `AccessShareLock` only and succeed on a read-only backend.

---

## 6. Analysis (`pgfr_analyze`)

### 6.1 Three new anomalies in `anomaly_report()`

Added to `pgfr_analyze/sql/01_core_metrics.sql` **before** the existing `XID_WRAPAROUND_RISK` check so that cause precedes symptom in the report. Each anomaly's `metric_value` and `recommendation` read the *typed* columns of the appropriate sidecar for the dominant holder at the latest snapshot.

**Semantics.** `anomaly_report()` is point-in-time at the latest snapshot in the window; callers dedupe adjacent firings if desired (the project's convention — see existing `XID_WRAPAROUND_RISK`). `CATALOG_XMIN_HORIZON_STALL` is **not** XOR with `XMIN_HORIZON_STALL` — both can fire simultaneously when a logical slot holds both `xmin` and `catalog_xmin` above threshold. Each anomaly skips when its source columns are NULL (historical snapshots from before this change).

Severity ladder separates **onset** (warning) from **wraparound-risk territory** (high/critical):

- `XMIN_HORIZON_STALL_WARNING` — severity `warning`. Fires when `xmin_data_horizon_age > xmin_stall_warning_age` (new config, default `50,000,000` xids). This is an **early signal**: the horizon has been stalled long enough that bloat is compounding on hot tables, but wraparound is not imminent. The previous design bolted attribution onto the existing 50%/80%-of-`autovacuum_freeze_max_age` thresholds, so on a cluster with `autovacuum_freeze_max_age=2B` the anomaly wouldn't fire until 1B xids of stall — far too late. The warning threshold is absolute, not relative, so it's useful regardless of `autovacuum_freeze_max_age`.
- `XMIN_HORIZON_STALL` — severity `high` at `xmin_data_horizon_age > 0.5 * autovacuum_freeze_max_age`; `critical` at `> 0.8 * autovacuum_freeze_max_age`. Source attribution selects the oldest holder across the sidecars:
  - **activity** (from `xmin_activity_holders`): `"terminate PID %s (user=%s, app=%s, db=%s, state=%s, xact_start=%s, query: %s)"` — uses `pid`, `usename`, `application_name`, `datname`, `state`, `xact_start`, `query_preview`. When `leader_pid IS NOT NULL` the holder is a parallel worker; the recommendation names the leader instead: `"terminate leader PID %s (parallel worker %s is a symptom)"`.
  - **slot** (from `xmin_slot_holders`): when `invalidation_reason IS NOT NULL` → `"slot '%s' is already invalidated (%s); DROP REPLICATION SLOT"`. When `wal_status = 'lost'` → `"slot '%s' has lost required WAL; DROP REPLICATION SLOT"`. Otherwise → `"DROP REPLICATION SLOT '%s' (type=%s, active=%s, restart_lsn=%s) — or fix the consumer if this slot is still needed"`.
  - **replication** (from `replication_snapshots` where `is_logical_walsender IS NOT TRUE`): `"review hot_standby_feedback on standby '%s' (addr=%s, pid=%s, sync_state=%s)"`. Logical walsenders are attributed via the slot sidecar instead — hot_standby_feedback advice is nonsense for them.
  - **prepared** (from `xmin_prepared_holders`): `"ROLLBACK PREPARED '%s' (owner=%s, database=%s, prepared_at=%s)"`.
  - **attribution fallback**: if the dominant source's sidecar is empty (e.g. `xmin_holders_collection_status = 'below_floor'` for the snapshot that crossed the threshold, or the sidecar row was pruned by partition GC), the anomaly still fires but `recommendation` is suffixed `" — holder detail not collected: <status>"`. Never silently misattribute.
- `CATALOG_XMIN_HORIZON_STALL` — severity `high` at `xmin_catalog_slot_age > 0.5 * autovacuum_freeze_max_age`, `critical` at `> 0.8`. Fires **independently** of the data anomalies: a logical slot can pin `catalog_xmin` while leaving `xmin` NULL, which elevates catalog-slot age but not data horizon. Recommendation always points at `xmin_slot_holders` rows with `slot_type = 'logical'` and non-null `catalog_xmin`, using the same invalidation/lost/active logic as the slot branch above.

### 6.2 New reader: `pgfr_analyze.xmin_horizon_history(p_start, p_end)`

`UNION ALL`s the three holder sidecars and the `backend_xmin` column on `replication_snapshots`, joined to `snapshots`, projecting to a uniform shape so forensics can see every horizon holder over a window in one scroll:

```sql
RETURNS TABLE (
    captured_at            TIMESTAMPTZ,
    xmin_data_horizon_age  BIGINT,
    xmin_catalog_slot_age  BIGINT,
    collection_status      TEXT,     -- from snapshots.xmin_holders_collection_status
    truncated_count        INTEGER,  -- from snapshots.xmin_holders_truncated_count
    source                 TEXT,     -- 'activity' | 'slot' | 'replication' | 'prepared'
    xmin_age               BIGINT,
    holder_key             TEXT,     -- pid / slot_name / application_name / gid
    holder_detail          TEXT      -- human-readable summary of source-specific cols
)
```

The `holder_detail` string is formatted per source (e.g. activity: `"leader_pid=%s app=%s user=%s state=%s query=%s"`). Rows with `collection_status != 'collected'` are emitted with NULL `source` / `xmin_age` / `holder_key` / `holder_detail` so gaps are visible in timeline scrolls. Operators who want fully structured columns query the sidecar tables directly. Analogous to `what_happened_at` and `incident_timeline`.

---

## 7. Tests — red/green/refactor TDD

Every implementation step is preceded by a failing test. Commit cadence mirrors the red/green/refactor loop.

### 7.0 Workflow

1. **Red** — write the full pgTAP suite first against `main`. Run it; every assertion fails. Commit (`tests: red phase for xmin horizon monitoring`).
2. **Green 1 — schema**. Implement §4 DDL only. Schema-existence assertions go green; behavior assertions still fail. Commit.
3. **Green 2 — collection**. Implement §5. Population and invariant assertions go green. Commit.
4. **Green 3 — analyzer**. Implement §6. Anomaly assertions go green. Commit.
5. **Refactor** — only once all tests are green. No new behavior allowed during refactor; any bugs found trigger a new red-phase test first.

The TDD discipline is what catches the bugs that surfaced in review (collector self-pin, floor-gate missing catalog stalls, XOR anomaly exclusivity, Appendix-A-style off-by-orders-of-magnitude math). Each of those becomes an explicit failing test before the code exists.

### 7.1 Red suite — `pgfr_record/tests/16_xmin_horizon.sql`

Schema assertions (go green after §4):

- Columns on `snapshots`: `activity_xmin`, `activity_xmin_age`, `slot_xmin`, `slot_xmin_age`, `slot_catalog_xmin`, `slot_catalog_xmin_age`, `replication_xmin`, `replication_xmin_age`, `prepared_xid`, `prepared_xid_age`, `xmin_data_horizon_age`, `xmin_catalog_slot_age`, `xmin_any_horizon_age`, `xmin_holders_collection_status`, `xmin_holders_truncated_count`.
- Columns on `replication_snapshots`: `backend_xmin`, `backend_xmin_age`, `slot_name`, `is_logical_walsender`.
- Tables exist: `xmin_activity_holders`, `xmin_slot_holders`, `xmin_prepared_holders`. Each has `sample_ts INTEGER` first-column PK.
- Activity-holder columns include `leader_pid`, `datname`, `usesysid`, `backend_xid`, `xact_age_seconds`, `query_age_seconds`, `queryid`, `query_preview`.
- Slot-holder columns include `conflicting` (`has_column` gated on `_pg_version() >= 16`), `invalidation_reason` (`_pg_version() >= 17`).
- Prepared-holder columns include `prepared_xid`, `prepared_xid_age`.

Population / invariants (go green after §5):

- `snapshot()` populates `xmin_data_horizon_age` and `xmin_catalog_slot_age` as non-negative.
- Invariant: `xmin_any_horizon_age >= xmin_data_horizon_age` and `xmin_any_horizon_age >= xmin_catalog_slot_age`.
- Invariant: `xmin_data_horizon_age >= greatest(activity_xmin_age, slot_xmin_age, replication_xmin_age, prepared_xid_age)` (NULL-safe).
- **Self-pin exclusion.** `snapshot()`'s own backend must not appear in `xmin_activity_holders`. Assertion runs after calling `snapshot()` within the test session: `SELECT count(*) = 0 FROM xmin_activity_holders WHERE snapshot_id = :last_id AND pid = pg_backend_pid()`.
- **Long-running txn attribution.** Two-session fixture (replaces the flaky `txid_current() + pg_sleep` pattern from v0.2):

  ```sql
  -- session A
  BEGIN ISOLATION LEVEL REPEATABLE READ;
  SELECT 1 FROM pg_class;  -- forces snapshot; backend_xmin becomes live
  -- (session holds open; pg_sleep not needed — RR snapshot persists until COMMIT)
  ```

  ```sql
  -- session B (the test)
  SELECT pgfr_record.snapshot();
  SELECT ok(EXISTS (
    SELECT 1 FROM pgfr_record.xmin_activity_holders
    WHERE snapshot_id = :latest AND pid = :session_a_pid AND backend_xmin IS NOT NULL
  ), 'session A appears in xmin_activity_holders with non-null backend_xmin');
  ```

  Implemented with `dblink` to spawn session A, matching the pattern already used in `tests/test_lock_non_snapshot.sql`.
- **Parallel worker → leader_pid.** Force parallel query via `SET max_parallel_workers_per_gather = 2`; assert any workers that appear in the holder table have `leader_pid IS NOT NULL`.
- **Below-floor.** Set `xmin_holders_min_age = 9223372036854775807` (practically infinite); call `snapshot()`; assert `xmin_activity_holders` / `xmin_slot_holders` / `xmin_prepared_holders` have zero rows for the new snapshot and `snapshots.xmin_holders_collection_status = 'below_floor'`. Aggregate age columns still populated.
- **Catalog-only gate.** Mock fixture: create a logical slot with `catalog_xmin` set but `xmin` NULL (simulate by creating via `pg_create_logical_replication_slot` with `pgoutput` after some DDL). Assert `xmin_slot_holders` row exists even when `xmin_data_horizon_age` < floor — proves per-sidecar gating works. Gated on `wal_level = 'logical'`; `skip()` otherwise.
- **Truncation count.** Set `xmin_holders_top_n = 1`; open two sessions with live `backend_xmin`; call `snapshot()`; assert `snapshots.xmin_holders_truncated_count >= 1`.

### 7.2 Red suite — `pgfr_analyze/tests/test_xmin_horizon.sql`

Analyzer assertions (go green after §6):

- Fresh DB fires no `XMIN_HORIZON_*` anomalies (analogous to existing `10_xid_wraparound.sql` fresh-DB assertion).
- Synthetic fixture A — warning onset: `UPDATE pgfr_record.snapshots SET xmin_data_horizon_age = 60000000 WHERE id = (SELECT max(id))` → assert `XMIN_HORIZON_STALL_WARNING` fires with severity `warning`.
- Synthetic fixture B — high: `xmin_data_horizon_age = 0.6 * autovacuum_freeze_max_age` → `XMIN_HORIZON_STALL` severity `high`.
- Synthetic fixture C — critical: `xmin_data_horizon_age = 0.9 * autovacuum_freeze_max_age` → severity `critical`.
- Synthetic fixture D — catalog independent: `xmin_catalog_slot_age = 0.6 * freeze_max_age`, `xmin_data_horizon_age = 0` → `CATALOG_XMIN_HORIZON_STALL` fires, data anomaly does NOT fire.
- Synthetic fixture E — both fire: `xmin_data_horizon_age = 0.6 * freeze_max_age` AND `xmin_catalog_slot_age = 0.6 * freeze_max_age` → both anomalies fire (verifies non-XOR).
- Attribution fallback: synthetic fixture where `xmin_data_horizon_age` is high but `xmin_holders_collection_status = 'below_floor'` → anomaly fires, `recommendation` contains `"holder detail not collected: below_floor"`.
- Parallel-worker recommendation: seed `xmin_activity_holders` with `leader_pid = 1234`; assert `recommendation` names the leader, not the worker pid.
- Logical walsender filtering: seed `replication_snapshots` with `is_logical_walsender = true` and the slot itself in `xmin_slot_holders`; assert attribution points at the slot, not at `hot_standby_feedback`.
- `xmin_horizon_history()` returns rows matching the fixtures, with `collection_status` and `truncated_count` populated.

### 7.3 Integration tests — `pgfr_record/tests/integration/`

Split out because they require multi-node infra and are skipped under the unit runner:

- **Hot standby feedback**: stand up a physical replica with `hot_standby_feedback = on`; run a long query on the standby; assert primary's `snapshots.replication_xmin_age` rises and `replication_snapshots` has a row with non-null `backend_xmin`, `is_logical_walsender = false`, and a matching `slot_name` when the replica uses a slot.
- **Cascading slots on a standby**: not v1; tracked as follow-up.

### 7.4 Refactor guardrails

- No assertion is allowed to be weakened during refactor. If a test becomes redundant, delete it; if it starts failing, investigate, don't relax.
- Tests must run under `./test.sh` on PG 15 / 16 / 17 / 18. Version-gated assertions use `skip()` + `_pg_version()`, never silent branches.

---

## 8. Docs

- `pgfr_record/README.md` — add an entry to the captured-metrics table covering the four xmin sources.
- `REFERENCE.md` — new section "xmin Horizon" documenting:
  - the fifteen new columns on `snapshots` (ten typed xmin/age pairs + three aggregate ages + two status columns)
  - the four new columns on `replication_snapshots` (`backend_xmin`, `backend_xmin_age`, `slot_name`, `is_logical_walsender`)
  - the three holder sidecars (`xmin_activity_holders`, `xmin_slot_holders`, `xmin_prepared_holders`) with full column lists
  - config keys: `xmin_holders_top_n`, `xmin_holders_min_age`, `xmin_stall_warning_age`, `xmin_capture_query_preview`
  - the three new anomalies (`XMIN_HORIZON_STALL_WARNING`, `XMIN_HORIZON_STALL`, `CATALOG_XMIN_HORIZON_STALL`) and their source-specific remediations
  - the `xmin_horizon_history()` reader
  - **xid-ordering caveat**: never order raw `xid` values directly; always use `age(xid)` captured at snapshot time (xid is 32-bit modular)
  - **query-text sensitivity note**: `query_preview` can contain literals, tokens, emails, tenant IDs. Set `xmin_capture_query_preview = false` to suppress the column entirely for privacy-sensitive deployments. Aligns with existing query-text retention policy for `statement_snapshots`.
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

Rows per snapshot at 60-second cadence (with the default `xmin_holders_min_age = 1,000,000` floor):

| Scenario                          | activity | slot | prepared | Notes |
|-----------------------------------|----------|------|----------|-------|
| Healthy, below floor              | 0        | 0    | 0        | `xmin_data_horizon_age` and `xmin_catalog_slot_age` both < floor. `xmin_holders_collection_status = 'below_floor'`. Only the aggregate age columns are written. |
| Data-horizon stall, single holder | 1        | 0    | 0        | One long-running activity xact above floor. |
| Catalog-only stall (logical slot) | 0        | 1    | 0        | Logical slot's `catalog_xmin` is above floor, `xmin_data_horizon_age` is not. Proves per-sidecar gating: slot sidecar populates, others stay empty. |
| Top-N cap saturated (ceiling)     | 5        | 5    | 1        | 5 concurrent data-horizon holders; 5 logical slots lagging (fan-out publisher); plus a stuck prepared xact. Conservative sizing ceiling — real systems almost never hit this. |

30-day **raw storage** projections (no rollup; all rows retained at snapshot cadence):

| Scenario                    | Per day  | 30 days raw |
|-----------------------------|----------|-------------|
| Healthy, below floor        | ~0.1 MB  | ~3 MB       |
| Data-horizon single holder  | ~1 MB    | ~30 MB      |
| Catalog-only stall          | ~0.3 MB  | ~9 MB       |
| Top-N cap saturated (ceiling)| ~11 MB  | ~325 MB     |

Healthy systems cost ~3 MB/month — the fifteen new columns on `snapshots` at ~75 B × 1440 × 30 ≈ 3.2 MB, which is the absolute floor. Holder sidecars remain empty. Cost only scales up when the horizon is actually stalled, which is when forensic data is wanted.

Reference point: `statement_snapshots` baseline is ~960 MiB/30d raw at `top_n=50` (SPEC.md §9.2). Worst-case holders are ~1/3 of that; typical is 1–2 orders of magnitude below. These are order-of-magnitude estimates — `query_preview` can TOAST, per-row overhead varies with index fillfactor, and observed numbers will vary.

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

- **Materialization vs. live views.** This is the core flight-recorder premise: by the time an operator looks at an xmin stall, the offending backend has disconnected, the abandoned slot has been dropped, and the prepared xact has been rolled back. A live view over `pg_stat_activity` / `pg_replication_slots` shows the present, not the past. Materialization at snapshot cadence is what makes the feature useful at all — otherwise this is just a prettier `\d pg_stat_activity`.
- **Top-N per source vs. oldest-only.** The postgres.ai query picks one row per source. A flight recorder wants the pile-up, not just the winner — a fleet of idle-in-transaction sessions all pinning similar xmins is a common failure mode and the single oldest tells you nothing about the pattern. Cost is bounded by `xmin_holders_top_n` (default 5): enough to reveal pile-ups, small enough that worst-case 30-day raw storage stays at ~325 MB. `xmin_holders_truncated_count` surfaces when the pile-up exceeds the cap.
- **Three typed tables vs. one `JSONB` holders table.** Per-source tables carry only the columns that apply, `\d pgfr_record.xmin_activity_holders` documents itself, and queries filter/sort on typed columns (`xact_start`, `restart_lsn`, `prepared_at`) without JSON extraction. Follows the project's existing sidecar pattern (`replication_snapshots`, `vacuum_progress_snapshots`).
- **Collection floor vs. always-collect.** Per-sidecar gating closes the catalog-only blind spot (a logical slot pinning `catalog_xmin` alone still writes slot rows). The remaining blind spot is bursts where xmin is briefly held below the floor — aggregate ages still capture the shape, only per-holder attribution is missing. Set `xmin_holders_min_age = 0` for always-collect.
- **Early-warning threshold separate from wraparound-risk thresholds.** The existing `XID_WRAPAROUND_RISK` already fires at 50%/80% of `autovacuum_freeze_max_age`. Reusing those thresholds for horizon stalls means the anomaly is useless as an onset signal — on a cluster with `autovacuum_freeze_max_age = 2B` the stall is at 1B xids before it's flagged. `xmin_stall_warning_age` (default 50M, absolute) gives operators a chance to act before bloat compounds.
- **`xmin_holders_collection_status` column.** Without it, an empty sidecar row is ambiguous: "nothing to record", "below floor", or "collector broke". The status column makes the ambiguity explicit — downstream readers can distinguish forensically absent data from actually absent events.
- **`xid` vs. `bigint` storage.** Storing both is mildly redundant but matches the source fidelity (`xid`) and the natural threshold/sort key (`bigint age`). Raw `xid` ordering is dangerous (modular); the docs note this.
- **Precomputed aggregate age columns.** The `greatest(...)` aggregates could be a view, but precomputing at write time (a) keeps analysis queries simple, (b) survives export via `pg_dump`, (c) lets anomalies filter-before-join, and (d) costs negligible bytes.
- **Standby collection.** Enumerated in §5: activity and slot sources populate on both primary and standby; `pg_stat_replication` fills only when cascading; prepared xacts are informational on standbys (primary's horizon is what matters for cleanup).

---

## 11. Non-goals

- No alerting integration. The anomalies populate `anomaly_report()`; shipping them to PagerDuty / Slack is outside the extension's scope.
- No automatic remediation. The `recommendation` column is advisory; the operator still issues the `pg_terminate_backend` / `DROP SLOT` / `ROLLBACK PREPARED`.
- No xid-freeze-progress tracking over time beyond what `datfrozenxid_age` already provides. That would require parsing `autovacuum` logs, which is out of scope (see the guide's log-based monitoring section for manual inspection).

---

## Appendix A. Example snapshot content

Scenario: a `BEGIN;` session (PID 48291) has been idle-in-transaction for ~4 hours, holding the xmin horizon at ~100.5M xids of age on a cluster with default `autovacuum_freeze_max_age = 200,000,000`. A physical replica `replica_west` has `hot_standby_feedback = on` so its `backend_xmin` tracks slightly younger. No logical slots, no prepared xacts, no parallel workers. Snapshot taken at `2026-04-24 14:32:00+00`.

`pgfr_record.snapshots` — new columns only:

```text
id                              | 12345
captured_at                     | 2026-04-24 14:32:00+00
activity_xmin                   | 789001234
activity_xmin_age               | 100500000
slot_xmin                       | (null)
slot_xmin_age                   | (null)
slot_catalog_xmin               | (null)
slot_catalog_xmin_age           | (null)
replication_xmin                | 789050000
replication_xmin_age            | 100450000
prepared_xid                    | (null)
prepared_xid_age                | (null)
xmin_data_horizon_age           | 100500000
xmin_catalog_slot_age           | 0
xmin_any_horizon_age            | 100500000
xmin_holders_collection_status  | collected
xmin_holders_truncated_count    | 0
```

`pgfr_record.xmin_activity_holders`:

```text
sample_ts | snapshot_id | pid   | leader_pid | datname | usename | application_name | state               | xact_age_seconds | query_age_seconds | backend_xmin | backend_xmin_age | query_preview
----------+-------------+-------+------------+---------+---------+------------------+---------------------+------------------+-------------------+--------------+------------------+----------------
41183     | 12345       | 48291 | (null)     | orders  | app_rw  | orders_worker    | idle in transaction | 14400            | 14400             | 789001234    | 100500000        | BEGIN
41183     | 12345       | 48299 | (null)     | reports | reports | report_batch     | active              | 120              | 45                | 789020000    | 100480000        | SELECT sum(amount) FROM large_ledger WHERE created_at > $1
```

`pgfr_record.replication_snapshots` — existing row, new columns highlighted:

```text
snapshot_id | pid | application_name | client_addr | state     | sync_state | slot_name     | is_logical_walsender | backend_xmin | backend_xmin_age
------------+-----+------------------+-------------+-----------+------------+---------------+----------------------+--------------+------------------
12345       | 301 | replica_west     | 10.0.2.7    | streaming | async      | replica_west  | false                | 789050000    | 100450000
```

`xmin_slot_holders`, `xmin_prepared_holders`: empty in this scenario.

`anomaly_report()` emits two rows (warning fired earlier and will still fire; stall has now crossed 50%):

```text
anomaly_type   | XMIN_HORIZON_STALL_WARNING
severity       | warning
description    | xmin horizon stalled for extended period
metric_value   | xmin_data_horizon_age=100,500,000 (onset warning at 50,000,000); dominant: activity
threshold      | xmin_data_horizon_age > 50,000,000
recommendation | terminate PID 48291 (user=app_rw, app=orders_worker, db=orders,
                 state=idle in transaction, xact_start=4h ago, query: BEGIN)

anomaly_type   | XMIN_HORIZON_STALL
severity       | high
description    | xmin horizon stalled by 'activity' source
metric_value   | xmin_data_horizon_age=100,500,000 (50.25% of autovacuum_freeze_max_age); dominant: activity
threshold      | xmin_data_horizon_age > 100,000,000 (50% of 200,000,000)
recommendation | terminate PID 48291 (user=app_rw, app=orders_worker, db=orders,
                 state=idle in transaction, xact_start=4h ago, query: BEGIN)
```

`CATALOG_XMIN_HORIZON_STALL` does not fire — `xmin_catalog_slot_age` is 0.
