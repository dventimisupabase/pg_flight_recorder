# xmin Horizon Monitoring

| Version | Date       | Author       |
|---------|------------|--------------|
| 0.1     | 2026-04-24 | Claude Code  |

Reference: [How to monitor xmin horizon — postgres.ai](https://postgres.ai/docs/postgres-howtos/performance-optimization/monitoring/how-to-monitor-xmin-horizon)

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
      order by age(backend_xmin) desc limit 1
    ) as data_xmin_activity,
    (select xmin from pg_replication_slots
      where xmin is not null
      order by age(xmin) desc limit 1
    ) as data_xmin_slot,
    (select catalog_xmin from pg_replication_slots
      where catalog_xmin is not null
      order by age(catalog_xmin) desc limit 1
    ) as catalog_xmin_slot,
    (select backend_xmin from pg_stat_replication
      where backend_xmin is not null
      order by age(backend_xmin) desc limit 1
    ) as data_xmin_replication,
    (select transaction from pg_prepared_xacts
      order by age(transaction) desc limit 1
    ) as data_xmin_prepared
)
select
  *,
  age(data_xmin_activity)    as data_xmin_activity_age,
  age(data_xmin_slot)        as data_xmin_slot_age,
  age(catalog_xmin_slot)     as catalog_xmin_slot_age,
  age(data_xmin_replication) as data_xmin_replication_age,
  age(data_xmin_prepared)    as data_xmin_prepared_age,
  greatest(
    age(data_xmin_activity),
    age(data_xmin_slot),
    age(data_xmin_replication),
    age(data_xmin_prepared)
  ) as data_horizon_age,
  greatest(
    age(data_xmin_activity),
    age(data_xmin_slot),
    age(data_xmin_replication),
    age(data_xmin_prepared),
    age(catalog_xmin_slot)
  ) as catalog_horizon_age
from bits;
```

The guide is explicit: it is never enough to monitor only long-running transactions; all four sources must be covered, and `data_horizon_age` (user-table cleanup) must be distinguished from `catalog_horizon_age` (system-catalog cleanup for logical replication) because they have different failure modes and different remediations.

---

## 4. Schema Changes

### 4.1 `pgfr_record.snapshots` — new columns

Add to `pgfr_record/sql/02_tables_legacy.sql` (via `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` in a `DO $$ BEGIN ... END $$` block, matching the existing delta-column pattern):

| Column                       | Type     | Source                                              |
|------------------------------|----------|-----------------------------------------------------|
| `data_xmin_activity`         | `xid`    | `pg_stat_activity.backend_xmin` (oldest)            |
| `data_xmin_activity_age`     | `bigint` | `age()` of above                                    |
| `data_xmin_slot`             | `xid`    | `pg_replication_slots.xmin` (oldest)                |
| `data_xmin_slot_age`         | `bigint` | `age()` of above                                    |
| `catalog_xmin_slot`          | `xid`    | `pg_replication_slots.catalog_xmin` (oldest)        |
| `catalog_xmin_slot_age`      | `bigint` | `age()` of above                                    |
| `data_xmin_replication`      | `xid`    | `pg_stat_replication.backend_xmin` (oldest)         |
| `data_xmin_replication_age`  | `bigint` | `age()` of above                                    |
| `data_xmin_prepared`         | `xid`    | `pg_prepared_xacts.transaction` (oldest)            |
| `data_xmin_prepared_age`     | `bigint` | `age()` of above                                    |
| `data_horizon_age`           | `bigint` | precomputed `greatest` of the four data-source ages |
| `catalog_horizon_age`        | `bigint` | precomputed `greatest` including `catalog_xmin_slot`|

Storing raw `xid` *and* `bigint` age keeps fidelity (xid is 32-bit circular) while making ORDER BY / threshold comparisons trivial.

### 4.2 `pgfr_record.replication_snapshots` — one new column

Add `backend_xmin xid` (and companion `backend_xmin_age bigint`). The table already has one row per replica per snapshot; adding the per-replica xmin here attributes source (3) at per-standby granularity.

### 4.3 New sidecar: `pgfr_record.xmin_horizon_holders`

When the dominant source is *activity* or *prepared xact*, the operator needs the PID / GID / query preview to act. A single "oldest" xmin on `snapshots` does not carry that context. Capture top-N holders per source per snapshot:

```sql
CREATE TABLE IF NOT EXISTS pgfr_record.xmin_horizon_holders (
    snapshot_id   INTEGER REFERENCES pgfr_record.snapshots(id) ON DELETE CASCADE,
    source        TEXT NOT NULL
                  CHECK (source IN ('activity','slot','replication','prepared')),
    identifier    TEXT NOT NULL,   -- pid::text, slot_name, or prepared gid
    xmin          XID,
    xmin_age      BIGINT,
    is_catalog    BOOLEAN NOT NULL DEFAULT false, -- true for slot.catalog_xmin rows
    extra         JSONB,           -- query_preview, application_name, slot_type, etc.
    PRIMARY KEY (snapshot_id, source, identifier, is_catalog)
);
CREATE INDEX IF NOT EXISTS xmin_horizon_holders_source_idx
    ON pgfr_record.xmin_horizon_holders(source, xmin_age DESC);
COMMENT ON TABLE pgfr_record.xmin_horizon_holders IS
  'Per-source xmin-horizon holders (activity / slot / replication / prepared). '
  'Top N per source per snapshot, bounded by xmin_holders_top_n config key (default 20).';
```

Top-N is configurable via `pgfr_record._get_config('xmin_holders_top_n', '20')`, aligning with the existing pattern used by `statements_top_n`. Rows with NULL xmin are not emitted.

---

## 5. Collection (`pgfr_record.snapshot()`)

A new section is inserted in `pgfr_record/sql/04b_functions_snapshot.sql` after the existing replication stats block and before the table-stats block. It runs:

1. Four aggregate queries matching the CTE in §3, writing into the new `snapshots` columns.
2. An extended `pg_stat_replication` read that also captures `backend_xmin` into `replication_snapshots`.
3. Top-N holders from each source into `xmin_horizon_holders`, filtered to `WHERE <xmin column> IS NOT NULL`, ordered by `age(xmin) DESC`, limited by the config key.

All three steps live under one outer `BEGIN / EXCEPTION WHEN OTHERS` with `RAISE WARNING` (never aborts a snapshot). Inner guards:

- `pg_prepared_xacts` is always-present but defensively wrapped `WHEN undefined_table THEN NULL`.
- `pg_stat_replication.backend_xmin` has existed since 9.4; no version branch.
- Section uses `_set_section_timeout()` (250 ms default) like every other section.

Cost is small: four aggregates over catalogs whose typical cardinality is 10–100 rows, holding `AccessShareLock` only.

---

## 6. Analysis (`pgfr_analyze`)

### 6.1 Two new anomalies in `anomaly_report()`

Added to `pgfr_analyze/sql/01_core_metrics.sql` **before** the existing `XID_WRAPAROUND_RISK` check so that cause precedes symptom in the report.

- `XMIN_HORIZON_STALL` — fires when `data_horizon_age` > 50% of `autovacuum_freeze_max_age` (critical at 80%). `metric_value` names the dominant source and its age; `recommendation` is source-specific:
  - activity → "terminate PID %s (%s, query: %s)"
  - slot → "DROP REPLICATION SLOT %s (lag %s WAL bytes)"
  - replication → "review hot_standby_feedback on standby %s"
  - prepared → "ROLLBACK PREPARED %s"
- `CATALOG_XMIN_HORIZON_STALL` — fires when only `catalog_horizon_age` is elevated (logical-replication catalog cleanup stall). Always points at `pg_replication_slots` with `slot_type = 'logical'`.

Both anomalies skip when their source columns are NULL (historical snapshots from before this change land).

### 6.2 New reader: `pgfr_analyze.xmin_horizon_history(p_start, p_end)`

Joins `snapshots` to `xmin_horizon_holders` and returns the time-series used during incident forensics:

```sql
RETURNS TABLE (
    captured_at          TIMESTAMPTZ,
    data_horizon_age     BIGINT,
    catalog_horizon_age  BIGINT,
    dominant_source      TEXT,
    holder_identifier    TEXT,
    holder_preview       TEXT
)
```

Analogous to `what_happened_at` and `incident_timeline`.

---

## 7. Tests

### 7.1 pgTAP: `pgfr_record/tests/16_xmin_horizon.sql`

- Column existence on `snapshots` (12 columns), `replication_snapshots` (2 columns), and `xmin_horizon_holders` (table + 5 columns).
- `snapshot()` populates `data_horizon_age` and `catalog_horizon_age` as non-negative.
- Simulated long-running transaction: open a second connection with `BEGIN; SELECT txid_current(); SELECT pg_sleep(2);`, call `snapshot()`, assert the calling backend's xmin appears in `xmin_horizon_holders` with `source = 'activity'`.
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
  - `replication_snapshots.backend_xmin`
  - the `xmin_horizon_holders` sidecar and its `source` values
  - `xmin_holders_top_n` config key
  - the two new anomalies and their remediations
  - the `xmin_horizon_history()` reader
- `CLAUDE.md` — unchanged (the additive-only guidance already covers this change).

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

- **Top-N per source vs. oldest-only.** The postgres.ai query picks one row per source. For forensics a flight recorder wants the full pile-up — a single long-running transaction is easy, but a fleet of idle-in-transaction sessions all pinning similar xmins is the more common failure mode and requires seeing all of them. Cost is bounded by `xmin_holders_top_n` (default 20).
- **`xid` vs. `bigint` storage.** Storing both is mildly redundant but matches the source fidelity (`xid`) and the natural threshold/sort key (`bigint age`). Query analysis defaults to the age column.
- **Precomputed `*_horizon_age` columns.** The two `greatest(...)` columns could be a view, but precomputing at write time (a) keeps analysis queries simple, (b) survives export via `pg_dump`, and (c) costs negligible bytes.
- **`pg_prepared_xacts` defensiveness.** The view is in core; wrapping with `WHEN undefined_table` is belt-and-suspenders for forks that disable it. Cost is one `EXCEPTION` block.
- **Standby collection.** The standby writes rows where `data_xmin_replication` is always NULL (because `pg_stat_replication` is empty there). Accepted — the recorder should still record the three other sources on standbys.

---

## 11. Non-goals

- No alerting integration. The anomalies populate `anomaly_report()`; shipping them to PagerDuty / Slack is outside the extension's scope.
- No automatic remediation. The `recommendation` column is advisory; the operator still issues the `pg_terminate_backend` / `DROP SLOT` / `ROLLBACK PREPARED`.
- No xid-freeze-progress tracking over time beyond what `datfrozenxid_age` already provides. That would require parsing `autovacuum` logs, which is out of scope (see the guide's log-based monitoring section for manual inspection).
