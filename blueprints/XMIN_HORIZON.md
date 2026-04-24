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

| Column                             | Type                        | Source                                                                                        |
|------------------------------------|-----------------------------|-----------------------------------------------------------------------------------------------|
| `activity_xmin`                    | `xid`                       | `pg_stat_activity.backend_xmin` (oldest, self- and worker-excluded; see §4.3.1); NULL = none  |
| `activity_xmin_age`                | `bigint`                    | `age()` of above; NULL when no holder                                                         |
| `slot_xmin`                        | `xid`                       | `pg_replication_slots.xmin` (oldest); NULL = none                                             |
| `slot_xmin_age`                    | `bigint`                    | `age()` of above; NULL when no holder                                                         |
| `slot_catalog_xmin`                | `xid`                       | `pg_replication_slots.catalog_xmin` (oldest); NULL = none                                     |
| `slot_catalog_xmin_age`            | `bigint`                    | `age()` of above; NULL when no holder. (`CATALOG_XMIN_HORIZON_STALL` reads this.)             |
| `replication_xmin`                 | `xid`                       | `pg_stat_replication.backend_xmin` (oldest, physical walsenders only); NULL = none            |
| `replication_xmin_age`             | `bigint`                    | `age()` of above; NULL when no holder                                                         |
| `prepared_xmin`                    | `xid`                       | `pg_prepared_xacts.transaction` (oldest); NULL = none                                         |
| `prepared_xmin_age`                | `bigint`                    | `age()` of above; NULL when no holder                                                         |
| `xmin_data_horizon_age`            | `bigint`                    | `greatest()` of the four data-source ages; NULL-safe (`greatest` ignores NULL); NULL iff all four sources absent |
| `xmin_any_horizon_age`             | `bigint GENERATED STORED`   | `GENERATED ALWAYS AS (greatest(xmin_data_horizon_age, slot_catalog_xmin_age)) STORED`         |
| `xmin_activity_collection_status`  | `text`                      | per-source: `collected` / `below_floor` / `collector_failed` / `not_available`                |
| `xmin_slot_collection_status`      | `text`                      | per-source status for slot holder collection                                                  |
| `xmin_prepared_collection_status`  | `text`                      | per-source status for prepared holder collection                                              |
| `xmin_replication_collection_status`| `text`                     | per-source status for replication_snapshots write                                             |
| `xmin_activity_truncated_count`    | `integer`                   | `max(0, actual_activity_holders - xmin_holders_top_n)`; NULL when status ≠ `collected`        |
| `xmin_slot_truncated_count`        | `integer`                   | same for slot                                                                                 |
| `xmin_prepared_truncated_count`    | `integer`                   | same for prepared (no cap on replication — `pg_stat_replication` is bounded by `max_wal_senders`) |

**NULL semantics.** Source ages are NULL when no holder exists for that source — not 0. An absent holder is qualitatively different from an age-zero holder; `NULL` preserves that distinction. Downstream analyzer code uses `COALESCE(age, 0) > threshold` only for threshold checks. `GREATEST()` is already NULL-safe in Postgres.

**Per-source status and truncated counts.** Previous versions used one global `xmin_holders_collection_status`, but a single snapshot can have mixed per-source states (e.g. activity `below_floor`, slot `collected`, prepared `collector_failed`). Per-source columns disambiguate without the JSONB overhead for a fixed, bounded set of sources.

**`xmin_any_horizon_age` is GENERATED STORED** so it cannot drift from its inputs (a future collector bug cannot make the three aggregate columns inconsistent). Supported on PG 15 / 16 / 17 / 18.

Storing raw `xid` *and* `bigint` age keeps fidelity (xid is 32-bit circular) while making ORDER BY / threshold comparisons trivial. **Never order raw `xid` values directly to determine oldest/newest — use `age(xid)` captured at snapshot time.**

### 4.2 `pgfr_record.replication_snapshots` — new columns

| Column                 | Type      | Source                                                                 |
|------------------------|-----------|------------------------------------------------------------------------|
| `backend_xmin`         | `xid`     | `pg_stat_replication.backend_xmin`                                     |
| `backend_xmin_age`     | `bigint`  | `age(backend_xmin)`                                                    |
| `slot_name`            | `text`    | `pg_replication_slots.slot_name` joined via `active_pid = pid`; NULL when walsender has no slot |
| `is_logical_walsender` | `boolean` | `COALESCE(s.slot_type = 'logical', false)` — genuinely binary, never three-valued               |

`slot_name` / `is_logical_walsender` matter for anomaly attribution: a logical walsender appears in `pg_stat_replication` too, but the actionable remediation is against its slot (look at subscriber lag / drop-or-advance the slot), not against `hot_standby_feedback` on a standby. The anomaly filter excludes rows with `is_logical_walsender = true` when attributing the `replication` source — those holders are already covered by `xmin_slot_holders`.

The `LEFT JOIN pg_replication_slots ON active_pid = pid` produces NULL `slot_type` for bare physical replication with no slot, which would make a naive `s.slot_type = 'logical'` evaluate to NULL. Wrapping the comparison in `COALESCE(..., false)` at write time yields a genuine boolean so downstream filters are simple `WHERE NOT is_logical_walsender` instead of NULL-safe `IS NOT TRUE`.

### 4.3 Per-source holder sidecar tables

The oldest-xmin per source (§4.1) answers "how bad is it"; the operator still needs to know *which* backend / slot / prepared xact / standby to act on. Per `CLAUDE.md`'s schema philosophy ("Strong typing catches errors early ... Schema-as-documentation"), each source gets its own typed sidecar, mirroring the existing pattern (`replication_snapshots`, `vacuum_progress_snapshots`).

All three tables are capped at `xmin_holders_top_n` rows per snapshot per source (configurable via `pgfr_record._get_config('xmin_holders_top_n', '5')`, default **5**). Five is enough to identify a pile-up without hoarding rows: the oldest holder is the actionable one, and four more provide attribution context when multiple sessions / slots lag together. Rows with NULL xmin are not emitted.

**Collection architecture.** Each source is read into a materialized CTE *once* per snapshot; aggregate-age columns on `snapshots` are derived from that CTE *unconditionally*; sidecar rows are inserted from the *same* CTE only when the floor condition passes. This resolves the chicken-and-egg of previous versions (where deriving aggregate from a floor-gated sidecar made aggregate NULL whenever sidecar was empty, contradicting the §8a "aggregate always populated" storage claim). Single read, two outputs, one row of truth.

**Floor gate** (storage mitigation), per-sidecar:

- `xmin_slot_holders` writes when `GREATEST(xmin_data_horizon_age, slot_catalog_xmin_age) > xmin_holders_min_age` — logical slots can pin `catalog_xmin` alone (data horizon untouched) and that's precisely what `CATALOG_XMIN_HORIZON_STALL` needs to attribute.
- `xmin_activity_holders` and the `replication_snapshots` xmin columns write when `xmin_data_horizon_age > xmin_holders_min_age`. Catalog-only stalls don't come from these sources.
- `xmin_prepared_holders` always writes (floor default `0`; see §4.3.3).

`xmin_holders_min_age` is configurable, default `1,000,000` xids (~2 min at modest TPS). Below the floor, no sidecar rows are written for that source; the corresponding per-source status is set to `below_floor`. Aggregate-age columns on `snapshots` remain populated regardless of the floor (they come from the source CTE, not the sidecar). Collector failures flow through the existing `collection_stats` / `_record_collection_end` infrastructure in `pgfr_record/sql/03_functions_util.sql`; the per-source status column sets `collector_failed` when the error path fires for that specific source.

**Config-interaction guard**: `xmin_holders_min_age` must be `<=` any of the `*_stall_warning_age` thresholds (§6.1) — otherwise warnings fire but sidecars stay empty, routing every warning through the attribution-fallback path. `install.sql` `RAISE NOTICE`s when it detects the inverted relationship.

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
  'Self-pin excluded via pid <> pg_backend_pid(). Parallel workers excluded '
  '(leader_pid IS NULL filter); leader appears once with its own backend_xmin.';
```

Column notes:

- `leader_pid`: NULL in every sidecar row because parallel workers are filtered out at write time (`WHERE leader_pid IS NULL`). Rationale: a parallel leader with N workers produces N+1 rows sharing the same `backend_xmin`, which wastes `top_n` slots on symptoms — the leader carries all the attribution value, workers are derivable via `pg_stat_activity` live lookup. Column kept for forward-compatibility and for the out-of-band `current_xmin_horizon_holder()` view (§6.3) that may surface workers on demand.
- `backend_type`: captured without filtering. Autovacuum workers *are* included — a vacuum of a multi-TB heap can hold `backend_xmin` for hours and is a real failure mode. The anomaly recommendation (§6.1) special-cases `backend_type = 'autovacuum worker'` to point at `pg_stat_progress_vacuum` instead of suggesting `pg_terminate_backend`.
- `datid` / `datname`: `pg_stat_activity` is cluster-wide; knowing the database focuses remediation and joins cleanly to `pg_stat_database` exports.
- `backend_xid` / `backend_xid_age`: context-only. `backend_xmin` is the true horizon holder signal; `backend_xid` tells you whether the xact has written anything yet.
- `xact_age_seconds` / `query_age_seconds`: surfaces long idle-in-transaction and long-running queries that are suspicious even when `backend_xmin` status varies. Documented caveat: a long `xact_start` without `backend_xmin` means the backend currently holds no snapshot, so it is not pinning the horizon *right now* — but it is a strong signal the backend is misbehaving.
- `query_preview` cap: `left(query, least(current_setting('track_activity_query_size')::int, xmin_query_preview_max_len))` (default 1024), with CR/LF/tabs stripped for grep-ability. Can be fully suppressed via `xmin_capture_query_preview = false` for privacy-sensitive deployments.

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
    sample_ts         INTEGER NOT NULL,              -- partition key; see §4.3.5
    snapshot_id       INTEGER NOT NULL,
    gid               TEXT NOT NULL,                 -- ROLLBACK PREPARED target
    prepared_xmin     XID,
    prepared_xmin_age BIGINT,
    prepared_at       TIMESTAMPTZ,
    owner             TEXT,
    database          TEXT,
    PRIMARY KEY (sample_ts, snapshot_id, gid)
);
COMMENT ON TABLE pgfr_record.xmin_prepared_holders IS
  'Prepared transactions holding the xmin horizon. ROLLBACK PREPARED target set. '
  'Always-collected: floor and cap configured independently (xmin_prepared_min_age, '
  'xmin_prepared_holders_top_n) because prepared xacts are rare, tiny, and high-signal.';
```

Naming note: the column is `prepared_xmin` for grep-friendly uniformity with the other `*_xmin` source columns, even though the underlying `pg_prepared_xacts.transaction` value is technically the xact's own xid (which serves as its implicit xmin for horizon purposes).

**Separate config knobs.** Unlike activity / slot sidecars, prepared-xact collection uses its own floor and cap:

- `xmin_prepared_min_age` — default `0`. Prepared xacts are rare enough that always recording them is cheap and forensically valuable; if one exists it's almost always interesting.
- `xmin_prepared_holders_top_n` — default `50`. A cluster with dozens of prepared xacts is itself a noteworthy event; the cap is only a safety valve for pathological dead-2PC-coordinator scenarios.

Both fall back to `xmin_holders_min_age` / `xmin_holders_top_n` if not set explicitly.

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

A new section is inserted in `pgfr_record/sql/04b_functions_snapshot.sql` after the existing replication stats block and before the table-stats block. Each source follows the same shape:

1. Read source into a **materialized CTE** once (bounded by `_set_section_timeout()`).
2. Derive aggregate-age column(s) on `snapshots` from that CTE unconditionally (NULL when CTE is empty — no holder for this source).
3. Conditionally `INSERT` top-N into the sidecar from the same CTE when the floor condition passes. Set per-source `xmin_*_collection_status` to `collected` / `below_floor`. Record `xmin_*_truncated_count` as `max(0, count(*) - top_n)`.

On exception in any per-source block: `RAISE WARNING`, status = `collector_failed`, `SQLERRM` logged to `collection_stats` via existing `_record_collection_end()` path. Failure of one source does not abort others.

### Source reads (sketches)

**Activity** — `pg_stat_activity`:

```sql
WITH activity AS MATERIALIZED (
    SELECT pid, leader_pid, datid, datname, usesysid, usename,
           application_name, client_addr, backend_type, state,
           backend_start, xact_start, query_start, state_change,
           wait_event_type, wait_event,
           backend_xid, age(backend_xid) AS backend_xid_age,
           backend_xmin, age(backend_xmin) AS backend_xmin_age,
           EXTRACT(epoch FROM now() - xact_start)::bigint  AS xact_age_seconds,
           EXTRACT(epoch FROM now() - query_start)::bigint AS query_age_seconds,
           left(regexp_replace(coalesce(query,''), '[\r\n\t]+', ' ', 'g'),
                least(current_setting('track_activity_query_size')::int,
                      pgfr_record._get_config('xmin_query_preview_max_len','1024')::int)) AS query_preview
    FROM pg_stat_activity
    WHERE backend_xmin IS NOT NULL
      AND pid <> pg_backend_pid()
      AND leader_pid IS NULL                  -- exclude parallel workers (leader carries attribution)
)
-- aggregate (unconditional):
SELECT max(backend_xmin_age) AS activity_xmin_age, ... FROM activity;
-- sidecar (conditional on xmin_data_horizon_age > xmin_holders_min_age):
INSERT INTO xmin_activity_holders (...) SELECT ... FROM activity
  ORDER BY backend_xmin_age DESC LIMIT xmin_holders_top_n;
```

`pid <> pg_backend_pid()` prevents `snapshot()` from self-pinning every snapshot. `leader_pid IS NULL` keeps parallel workers out of the sidecar; the leader appears once with its own `backend_xmin`. Autovacuum workers are **not** excluded — a long vacuum on a multi-TB heap is a real horizon-holding failure mode and the recorder should capture it; the anomaly (§6.1) special-cases `backend_type = 'autovacuum worker'` in the recommendation text.

**Replication** — `pg_stat_replication LEFT JOIN pg_replication_slots ON active_pid = pid`. Writes `slot_name` and `is_logical_walsender := COALESCE(s.slot_type = 'logical', false)`. Aggregate `replication_xmin_age` is derived from rows with `is_logical_walsender = false` — logical walsenders are attributed via `xmin_slot_holders` because their `backend_xmin` is a mirror of the slot's xmin and the actionable remediation is against the slot (subscriber lag), not `hot_standby_feedback`.

**Slot** — `pg_replication_slots WHERE xmin IS NOT NULL OR catalog_xmin IS NOT NULL`. `conflicting` and `invalidation_reason` populated conditionally on `_pg_version() >= 16` / `>= 17`. Gate: `GREATEST(xmin_data_horizon_age, slot_catalog_xmin_age) > xmin_holders_min_age` — logical-only catalog stalls still write.

**Prepared** — `pg_prepared_xacts`. Own floor `xmin_prepared_min_age` (default 0) and cap `xmin_prepared_holders_top_n` (default 50); see §4.3.3.

Cost is small: four catalog reads with `AccessShareLock` only. Materialized CTEs guarantee each source is read exactly once per snapshot — no race between aggregate and sidecar, no dependency on the order of reads.

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

Severity ladder separates **onset** (warning) from **wraparound-risk territory** (high/critical). Data and catalog horizons both get a warning tier for symmetry — a logical slot slowly leaking `catalog_xmin` over days is exactly the case warning severity is meant to catch.

- `XMIN_HORIZON_STALL_WARNING` — severity `warning`. Fires when `xmin_data_horizon_age > xmin_stall_warning_age` (new config, default `50,000,000` xids, absolute not relative). Early signal: bloat compounding on hot tables, wraparound not imminent.
- `XMIN_HORIZON_STALL` — severity `high` at `xmin_data_horizon_age > 0.5 * autovacuum_freeze_max_age`; `critical` at `> 0.8 *`.
- `CATALOG_XMIN_HORIZON_STALL_WARNING` — severity `warning`. Fires when `slot_catalog_xmin_age > xmin_catalog_stall_warning_age` (new config, default `50,000,000` xids).
- `CATALOG_XMIN_HORIZON_STALL` — severity `high` at `slot_catalog_xmin_age > 0.5 * autovacuum_freeze_max_age`; `critical` at `> 0.8 *`.

Data and catalog anomalies fire **independently** — both can fire at the same severity level when a logical slot pins both `xmin` and `catalog_xmin` above threshold.

**Attribution tie-breaking.** When two sources have the same oldest age (common — a long activity txn and its walsender feedback mirror each other exactly), the dominant source is picked by priority, not by floating-point luck:

```text
slot > prepared > activity > replication
```

Rationale: persistent holders (slots, prepared xacts) are almost always the real cause when present at similar ages; walsender feedback is a mirror of primary-side holders and picking it first would leak remediation to the wrong side. Priority is a fixed tiebreaker only — a strictly-older source of any type always wins.

**Source-specific recommendation text** (soft-first, terminate-last):

- **activity** (from `xmin_activity_holders`):
  - `backend_type = 'autovacuum worker'`: `"long autovacuum on %s.%s (pid=%s) holding xmin %s old — check pg_stat_progress_vacuum; do NOT terminate unless vacuum is stuck"`.
  - `state = 'active'`: `"investigate PID %s (user=%s, app=%s, db=%s, query: %s) — try pg_cancel_backend(%s) first; escalate to pg_terminate_backend if cancellation does not release xmin"`.
  - `state LIKE 'idle in transaction%'`: `"PID %s has been idle in transaction for %s (user=%s, app=%s, db=%s) — pg_terminate_backend(%s) is usually appropriate"`.
- **slot** (from `xmin_slot_holders`):
  - `invalidation_reason IS NOT NULL`: `"slot '%s' is already invalidated (%s); DROP REPLICATION SLOT"`.
  - `wal_status = 'lost'`: `"slot '%s' has lost required WAL; DROP REPLICATION SLOT"`.
  - else: `"investigate slot '%s' (type=%s, active=%s, restart_lsn=%s); advance or drop the slot once subscriber state is confirmed"`.
- **replication** (from `replication_snapshots` where `NOT is_logical_walsender`):
  - `"review hot_standby_feedback on standby '%s' (addr=%s, pid=%s, sync_state=%s)"` — and when `slot_name` matches a row in `xmin_slot_holders` for the same snapshot, append: `"; related physical slot '%s' also present — the walsender feedback and the slot xmin describe the same standby, not two separate problems"`.
- **prepared** (from `xmin_prepared_holders`): `"ROLLBACK PREPARED '%s' (owner=%s, database=%s, prepared_at=%s)"`.

**Attribution fallback**: when the dominant source's sidecar is empty (per-source status ≠ `collected` for that source), the anomaly fires with `recommendation` suffixed `" — holder detail not collected: <per-source-status>"`. Never silently misattribute.

**Autovacuum worker caveat**: because the collector no longer filters autovacuum workers from the sidecar (see §5), they *can* appear as the dominant holder. The recommendation special-case above routes them to `pg_stat_progress_vacuum` instead of suggesting termination — an operator trying to terminate a 6-hour vacuum on a 2 TB table would just set progress back to zero.

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
