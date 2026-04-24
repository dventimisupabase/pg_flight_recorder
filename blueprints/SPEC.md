# Storage Overhaul: Partition-Based Retention, Compact Storage, Zero Bloat

| Version | Date       | Author    |
|---------|------------|-----------|
| 2.7     | 2026-02-26 | @NikolayS |

---

## Changelog

| Version | Changes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
|---------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2.7     | §9.2 baseline measurement complete (Hetzner cx22, PG 17.4, pgbench scale=50, 6.7h of pg_cron collection): Section 3 table updated with observed bytes/row and 30-day projections; confirmed statement_snapshots dominates at 466 bytes/row (960 MiB/30d at top_n=50, ~94 GiB at pgss.max=5000); confirmed config_snapshots change-log model effective (~1 MiB/30d); baseline_measure.sql corrected for actual collection_stats schema                                                                                                                                                                |
| 2.6     | Sixth-pass reviews: clean-restart desync trap fixed (check stats_reset not just emptiness); TRUNCATE lock_timeout 2s→50ms (FIFO queue stall); dealloc is cluster-wide not per-db; logical replication TRUNCATE poison pill + publication workaround; _partition_inventory() runtime assertions; JIT call-discipline for EXECUTE                                                                                                                                                                                                                                                                      |
| 2.5     | Fifth-pass reviews: Q5 BigInt column type + sequence both required; BRIN/B-tree non-overlapping paths + pages_per_range workload note; advisory xact_lock held for full snapshot run; JIT inheritance via EXECUTE clarified; `_partition_inventory()` bound parsing fragility + single-column RANGE assumption; GC cadence configurable; best-effort retention under lock contention; ring EXECUTE plan-cache trade-off documented; skip-tick observability counter                                                                                                                                  |
| 2.4     | Fourth-pass reviews: two-tier GC (nightly TRUNCATE + monthly drop_ancient_partitions); fix TRUNCATE lock framing; fix advisory lock race — skip tick if rebuild in flight; lock_timeout on TRUNCATE; `_partition_inventory()` defined; `_ensure_partition()` O(1) happy path; BRIN pages_per_range=8 + correlation check; WAL section updated for TRUNCATE vs DROP vs DELETE; benchmark headers fixed; pg_stat_reset_single_table_counters() note; ring buffer reader uses EXECUTE by partition name; Q8 guardrails updated for accumulation math                                                    |
| 2.3     | Replace DROP/DETACH with TRUNCATE for retention — eliminates dblink dependency, transaction-context trap, orphan tracking, and two-phase state machine; partition definitions accumulate but empty partitions are pruned automatically; `drop_old_partitions()` → `truncate_old_partitions()` throughout                                                                                                                                                                                                                                                                                             |
| 2.2     | Third-pass reviews: DETACH CONCURRENTLY transaction trap + dblink/externalize options; advisory lock on _rebuild_statement_last_state; ANALYZE after rebuild; INSERT...ON CONFLICT DO UPDATE mandated (HOT); HOT DDL comment + pgTAP guard; remove thundering-herd spread suggestion; ring buffer reader views exclude "next" partition; two-phase GC orphan detection; partition_gc_health view; partition_gc_state self-cleanup (7-day TTL); BRIN index on sample_ts for time-range queries; generic plan pruning test; Phase 2 BIGSERIAL sequence monotonicity; PGSS collection failure isolation |
| 2.1     | Second-pass reviews: add `toplevel` to composite key (PG14+ correctness); HOT-friendly `statement_last_state` with fillfactor+autovacuum; explicit crash recovery protocol (_rebuild_statement_last_state); daily TRUNCATE+rebuild semantics; PG14 minimum version declared in §2; `drop_old_partitions()` runs hourly + loops all eligible + partition_gc_state table + statement_timeout; dual-write cutover checklist; BIGSERIAL+dual-write synergy; soften Q3 partition pruning; relcache safety envelope in Q8; §9.8 references last-state join not DISTINCT ON; §9.12 pass/fail criteria       |
| 2.0     | Incorporate three external reviewer findings: replace DISTINCT ON with last-state side table (§5.2); function-level JIT disable (§6.3); UTC enforcement + index definitions + int4 horizon (§7.1); runtime partition ensure + pg_catalog-based drop + lock_timeout + DETACH CONCURRENTLY (§7.2); drop FK cascade recommendation (Q1); dual-write rollback strategy (Q2); partition pruning with explicit bounds (Q3); pg_stat_statements.max tracking (Q7); partition count guardrails (Q8); WAL benchmark (§9.11); high-churn benchmark (§9.12); expanded pgTAP suite (§9.13)                       |
| 1.5     | Distinguish `pg_stat_statements_reset()` (PGSS) from `pg_stat_reset()` (global stats) — both must be tested, §9.10 expanded                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| 1.4     | Fix stale `captured_at` references throughout — queries, indexes, prose all use `sample_ts` consistently                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| 1.3     | Adopt `int4 sample_ts` + `epoch()` from pg_ash (Q6); flag `snapshot_id` integer overflow risk (Q5); fix `DISTINCT ON (queryid, dbid, userid)` — queryid alone is not unique in PGSS; all MiB figures marked as estimates with single section-level note; fix cross-references §9.5, Q3                                                                                                                                                                                                                                                                                                               |
| 1.2     | Add §9.2 baseline measurement (run first); correct storage estimates to use `pg_stat_statements.max = 5000`; `config_snapshots` flagged as not benchmarked, not closed; row size assumption (280 bytes/row) made explicit                                                                                                                                                                                                                                                                                                                                                                            |
| 1.1     | Add sparse storage design (§5); reader function patterns (§6); expand benchmarking with extreme scenarios, simulated long runs, bloat comparison (§9)                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| 1.0     | Initial spec: partition-based retention, zero DELETE, TRUNCATE rotation for ring buffers                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |

---

## Table of Contents

- [Implementation Progress](#implementation-progress)

1. [Background and Motivation](#1-background-and-motivation)
2. [Scope and Constraints](#2-scope-and-constraints)
3. [Storage Analysis: Where the Problem Actually Is](#3-storage-analysis-where-the-problem-actually-is)
4. [Root Cause](#4-root-cause)
5. [Sparse Storage: Store Only What Changed](#5-sparse-storage-store-only-what-changed)
6. [Reader Functions for Sparse Data](#6-reader-functions-for-sparse-data)
7. [Proposed Solution: N Daily Partitions, No DELETE](#7-proposed-solution-n-daily-partitions-no-delete)
8. [Retention Model](#8-retention-model)
9. [Benchmarking and Testing](#9-benchmarking-and-testing)
10. [Open Questions](#10-open-questions)

---

## Implementation Progress

### Phase 1 — sparse inserts, partition infrastructure, v2 readers (target: `storage-overhaul-spec`)

- [x] `statement_snapshots_v2` — partitioned table with `int4 sample_ts` (PR #5)
- [x] `table_snapshots_v2`, `index_snapshots_v2` — partitioned tables (PR #5)
- [x] `_ensure_partition()` — O(1) happy path, UTC-enforced bounds, B-tree + BRIN indexes (PR #6)
- [x] `_partition_inventory()` — scans `pg_inherits`, returns bounds + empty flag (PR #6)
- [x] `truncate_old_partitions()` — nightly GC, 50 ms lock timeout, best-effort (PR #7)
- [x] `drop_ancient_partitions()` — monthly GC, empty-only, 2× retention guard (PR #7)
- [x] `partition_gc_health` view (PR #7)
- [x] `statement_last_state` — HOT-friendly side table, fillfactor=90 (PR #8)
- [x] `_rebuild_statement_last_state()` — advisory lock, ANALYZE after rebuild (PR #8)
- [x] `_collect_statement_snapshot_sparse()` — clean-restart desync trap, dealloc tracking (PR #9)
- [x] `table_last_state`, `index_last_state` + sparse collectors (PR #12)
- [x] `migrate_phase1.sql` — migration path for existing installations (PR #10, Q2 resolved)
- [x] `pgfr_analyze` v2-native reader functions — `statement_activity_v2`, `table_activity_v2`, `index_activity_v2` (PR #11, Q2b resolved)
- [x] pg_cron jobs: `pgfr_truncate_partitions`, `pgfr_drop_ancient_partitions` (PR #7; renamed from hyphenated form per #59)
- [x] pgTAP suite — 688 assertions across 20 test files
- [x] PG18 compatibility — `pg_stat_wal` column removals, PGSS column renames, `_ensure_partition()` index fix (commit `c5b7f52`)

### Phase 2 — ring buffer redesign (target: `storage-overhaul` on fork of `dventimisupabase/pg-flight-recorder`)

- [x] Phase 2 ring buffer code merged to `storage-overhaul-spec` (cherry-pick from `dventimisupabase` commit `6e8124b`)
- [x] `ring_config` singleton table
- [x] `wait_samples_0/1/2`, `lock_samples_0/1/2` — LOGGED, LIST-partitioned by slot
- [x] `wait_event_map` — independent dictionary (not shared with `pg_ash`)
- [x] `query_map_0/1/2` — per-partition query dictionaries, TRUNCATE on rotation
- [x] `query_map_all` view — union of all per-partition query maps
- [x] `rotate_ring()` — advisory-lock protected, slot advance + TRUNCATE oldest partition + sequence reset
- [x] `ring_current_slot()` helper
- [x] `_register_wait()` — race-safe upsert into `wait_event_map`
- [x] `_register_query()` — dynamic dispatch insert into current slot's `query_map`
- [x] `sample_ring()` — INSERT-based, reads `pg_stat_activity`, integer[] encoding
- [x] `recent_waits_v2` reader view — decodes integer[] to human-readable wait events
- [x] pg_cron jobs: `pgfr_sample_ring` (every minute), `pgfr_rotate_ring` (every 2h) — renamed from hyphenated form per #59
- [x] pgTAP suite: `test_ring_buffer.sql` — 26 assertions, all pass on PG18
- [x] PG18 compat applied to Phase 2 code (commit `d1d2b24`)
- [x] `activity_samples_0/1/2` — LOGGED, LIST-partitioned, top 25 sessions per tick (commit `4b0fc32`)
- [x] `lock_type_map` — compact int→text dictionary, 12 lock types pre-seeded
- [x] rewrite `flush_ring_to_aggregates()` — reads `wait_samples`/`lock_samples`/`activity_samples`; decodes integer[] via `wait_event_map`
- [x] rewrite `archive_ring_samples()` — reads v2 ring tables; decodes lock_type via `lock_type_map`
- [x] `sample_ring()` v2 — adds activity INSERT (top 25 sessions by query age) to existing wait+lock sampling
- [x] update `pgfr_analyze/install.sql` reader functions — `recent_waits_current()`, `recent_activity_current()`, `recent_locks_current()`, `wait_summary()` all rewritten for v2 ring tables (commit `4885dd2`)
- [x] benchmark: ring bloat before vs after — `BENCH_RING.md` (commit `c374c8e`): 95% size reduction, 0 dead tuples vs 543, 175 bytes/row measured

### Phase 3 — partition all remaining tables

- [x] `snapshots_v2`, `replication_snapshots_v2`, `vacuum_progress_snapshots_v2` — daily RANGE partitions, dual-write via trigger (commit `f32c900`)
- [x] archive tables (`activity_samples_archive_v2`, `lock_samples_archive_v2`, `wait_samples_archive_v2`) — daily RANGE partitions (commit `90f2884`)
- [x] `retention_archive_days` GC wired — `_partition_inventory()` uses two-tier cutoffs: `retention_snapshots_days` for snapshot tables, `retention_archive_days` for `*_archive_v2` tables (commit `90f2884`)
- [x] disable `cleanup()` DELETE paths — `pgfr_cleanup` cron replaced with partition GC jobs in migration (commit `cc57d51`)
- [x] deprecate old config key aliases — _resolve_config_key(), migrate_config_keys(), install.sql auto-migration (commit 780e41f)
- [x] migration script — `migrate_phase3.sql` + `migrate_phase3_rollback.sql` (commit `cc57d51`):
  - pre-flight: verifies v2 tables exist and have data
  - renames 11 legacy tables to `_legacy`
  - creates backwards-compat UNION ALL views for all 9 migrated tables
  - INSTEAD OF INSERT triggers on all 6 collector-targeted views
  - `snapshot()` routes to v2 with zero warnings post-migration
  - rollback script verified end-to-end

**GC invariants (locked):**

- Ring buffer (`wait_samples_N`, `lock_samples_N`, `activity_samples_N`): TRUNCATE only via `rotate_ring()` — no DELETE, no DROP
- Daily RANGE partitions: TRUNCATE (nightly) → DROP empty shell (monthly) — no DELETE ever
- `cleanup()` DELETE paths remain only for legacy heap tables during transition period

---

## 1. Background and Motivation

pg-flight-recorder records comprehensive PostgreSQL telemetry continuously via
pg_cron — wait events, active sessions, lock contention, WAL activity, checkpoints,
I/O, table and index statistics, query performance (`pg_stat_statements`),
replication state, and configuration. The data accumulates in a set of LOGGED tables
with DELETE-based retention managed by periodic `cleanup()` calls.

At default configuration (1-minute snapshot interval, 30-day retention,
`pg_stat_statements.max = 5000`), the naive full-insert model for `statement_snapshots`
alone generates approximately 2,024 MiB per day (5,000 queryids × 1,440 ticks/day
× ~280 bytes/row) — and every `cleanup()` run generates that volume as dead tuples
in a single transaction, leaving autovacuum to reclaim gigabytes of bloat per cycle.

This document proposes a storage redesign that eliminates DELETE-based retention
entirely and stops storing redundant data. No changes to what is collected, at what
frequency, or what telemetry is available.

---

## 2. Scope and Constraints

### What this overhaul does

- Stop inserting rows when nothing changed since the last snapshot
- Replace DELETE-based retention with daily partition DROP across all tables
- Introduce N daily partitions where N = configured retention in days
- Eliminate all dead tuples from retention operations

### Minimum supported PostgreSQL version

**PG14** is the minimum version for the full feature set. PG14 provides:

- `pg_stat_statements_info` (dealloc counter, stats_reset)
- `stats_since` column in `pg_stat_statements`
- `toplevel` column in `pg_stat_statements` (affects composite key — see §5.2)
- `pg_stat_wal` (WAL volume measurement)

PG13 is not in scope. Features that require PG14+ are not gated with version
conditionals — the minimum version assumption is load-bearing throughout.

### What this overhaul does NOT do

- **No new metrics** — no additional columns, no new data sources
- **No frequency changes** — snapshot intervals stay as configured
- **No changes to `pgfr_analyze` or `pgfr_control`** — out of scope
- **No changes to safety mechanisms** — circuit breaker, load shedding,
  section timeouts, `snapshot_based_collection` all preserved as-is

### One intentional behavioral change: sparse collection

The collection functions for `statement_snapshots`, `table_snapshots`, and
`index_snapshots` will skip inserting rows when nothing changed since the last
snapshot — following the model already implemented in `config_snapshots`. A missing
row means "no change since the last stored row." Reader functions reconstruct the
full state at any timestamp via `DISTINCT ON ... ORDER BY sample_ts DESC` (reader functions; not the collection path).

---

## 3. Storage Analysis: Where the Problem Actually Is

At default configuration (1-minute snapshots, `pg_stat_statements.max = 5000`,
30-day retention). Two columns shown: naive (full insert every tick) vs actual
current behavior.

**§9.2 baseline measured on 2026-02-26 on Hetzner cx22 (2 vCPU / 4 GiB RAM),
Ubuntu 24.04, PostgreSQL 17.4, `pg_stat_statements.max = 5000`,
`statements_top_n = 50` (default), `table_stats_top_n = 50` (default).
6.7 hours of pg_cron collection with pgbench workload (scale=50, TPS ≈ 2,552).
Observed bytes/row used for 30-day projections. Full detail: [Issue #4](https://github.com/NikolayS/pg-flight-recorder/issues/4).**

**Note: PG18 not yet supported** — measurements apply to PG 15–17 only.
**Scope limitations**: single-database setup, no streaming replication, pgbench workload only. Real production numbers may vary.

| Table                       | Rows at 30d (projected)                                | ~MiB (projected)                                     | Actual insert behavior                                         | bytes/row (observed) | Priority |
|-----------------------------|--------------------------------------------------------|------------------------------------------------------|----------------------------------------------------------------|----------------------|----------|
| `config_snapshots`          | ~5,760                                                 | ~1                                                   | **Change-log only** — 52 rows in 6.7 h on idle cluster         | 157                  | P1       |
| `db_role_config_snapshots`  | ~0                                                     | ~0                                                   | **Change-log only** — 0 rows observed (no role config changes) | n/a                  | P1       |
| `statement_snapshots`       | 2,160,000 (top_n=50) / **216,000,000** (pgss.max=5000) | **960 MiB** (top_n=50) / **~94 GiB** (pgss.max=5000) | Full insert every minute, no dedup                             | **466**              | **P0**   |
| `table_snapshots`           | 2,160,000                                              | **468 MiB**                                          | Full insert every minute, no dedup                             | **227**              | **P0**   |
| `index_snapshots`           | ~2,195,000                                             | **176 MiB**                                          | Full insert every minute, no dedup                             | **84**               | **P0**   |
| `snapshots` (parent)        | 43,200                                                 | ~19 MiB                                              | Full insert every minute                                       | 457                  | **P1**   |
| `replication_snapshots`     | 0                                                      | ~0                                                   | Full insert every minute (0 rows — no replication on bench)    | n/a                  | **P1**   |
| `activity_samples_archive`  | ~139,000                                               | ~28 MiB                                              | Ring flush every 15 min                                        | 212                  | **P1**   |
| `wait_samples_archive`      | ~345,000                                               | ~36 MiB                                              | Ring flush every 15 min                                        | 108                  | **P1**   |
| Ring buffers (combined)     | ~27,000 (fixed)                                        | ~16 MiB                                              | UPDATE overwrite                                               | 61–136               | **P2**   |
| Aggregate tables (combined) | ~167,000                                               | ~25 MiB                                              | Aggregated from ring flush                                     | 141–455              | **P2**   |

*Row projections for statement_snapshots, table_snapshots, and index_snapshots represent worst-case (top_n fully saturated). Observed rates were 40–55% lower (~32 rows/tick for statement_snapshots vs. 50 theoretical max).*

### Key findings

**`config_snapshots` uses the right approach — confirmed by §9.2 measurement.**
The upstream `_collect_config_snapshot()` function stores only parameters that
changed since the last snapshot — the correct design and the template for the
remaining tables. **Measured: 52 rows in 6.7 hours on a stable cluster (≈8 rows/h,
157 bytes/row) — confirming the ~1 MiB/30-day estimate.** On a cloud instance
with frequent `pg_reload_conf()` or `SET` commands the rate could be higher, but
the change-log approach is sound and effective.

**`statement_snapshots` is the dominant problem — confirmed by §9.2 measurement.**
At default `statements_top_n = 50` the observed rate is 50 rows/tick × 1,440
ticks/day = **72,000 rows/day** at **466 bytes/row = 960 MiB/30 days**.
At `pg_stat_statements.max = 5000` (the full PGSS capacity, no top-n filter)
the rate would be 5,000 rows/tick = **216,000,000 rows/30 days ≈ 94 GiB**.
A query that ran once 29 days ago has 43,200 identical rows, every one redundant.

Note: `statements_top_n = 50` (the default collection limit) significantly
understates the potential problem. The relevant ceiling for worst-case estimation
is `pg_stat_statements.max = 5000` — the number of distinct queryids PostgreSQL
tracks. The fix (sparse storage) applies equally to both configurations.

**The problem has two independent axes that compound each other:**

1. **Redundant inserts** — storing identical rows every minute when nothing changed
2. **DELETE-based retention** — generating millions of dead tuples per cleanup cycle

Both must be fixed. Fixing only one halves the problem at best.

**The hot ring buffers have a correctness problem, not a volume problem.** Dead
tuples from UPDATE-based overwrite on UNLOGGED tables are real but the total
affected volume is under 20 MiB. Important to fix, but not the storage crisis.

---

## 4. Root Cause

Every snapshot child table is a plain LOGGED heap table with append-only inserts
and DELETE-based retention. The `cleanup()` function runs:

```sql
delete from pgfr_record.snapshots where captured_at < v_cutoff;
-- cascades to some children; others use separate DELETE statements:

delete from pgfr_record.statement_snapshots
where snapshot_id in (
    select id from pgfr_record.snapshots where captured_at < v_cutoff
);
-- repeated for table_snapshots, index_snapshots, config_snapshots, ...
```

At 30-day retention with 5,000 queryids:

- 216,000,000 rows potentially deleted from `statement_snapshots` in one transaction
- All become dead tuples simultaneously
- Autovacuum must reclaim tens of gigabytes of bloat per cycle
- The correlated subquery performs a sequential scan of the full table on every run
- On a busy server, autovacuum may never catch up — bloat compounds indefinitely

Additionally, `statement_snapshots` is not cleaned via FK cascade — it uses a
separate DELETE with an independent cutoff that can differ from the parent's cutoff.
Parent and child can drift out of sync, leaving orphaned rows that no cleanup pass
ever removes.

---

## 5. Sparse Storage: Store Only What Changed

### 5.1 The config_snapshots model (already implemented)

The upstream `_collect_config_snapshot()` function:

1. On the first snapshot: stores all tracked parameters (~65 rows)
2. On every subsequent snapshot: compares current `pg_settings` against the most
   recent stored values via `DISTINCT ON (name) ORDER BY snapshot_id DESC`
3. Inserts only rows where `setting`, `source`, or `sourcefile` changed

In a stable environment this produces very few rows after the initial snapshot.
Whether "very few" means dozens or thousands in real deployments has not yet been
measured — see §9.2. This is the template for all other tables.

### 5.2 Apply to `statement_snapshots` (PGSS)

`pg_stat_statements` exposes cumulative counters: `calls`, `total_exec_time`,
`rows`, `shared_blks_hit`, etc. A query that has not been called since the last
snapshot has identical counter values. There is no reason to store another row.

**Last-state side table (preferred over DISTINCT ON):**

Using `DISTINCT ON (queryid, dbid, userid) ORDER BY sample_ts DESC` against
today's partition grows expensive as the day progresses — by 23:59 the partition
may contain 7.2M rows, and PostgreSQL cannot perform a loose index scan natively.
At 5,000 queryids × 1-minute ticks, this becomes a significant CPU spike every
tick. The preferred approach is a dedicated last-state table.

**Composite key includes `toplevel` (PG14+):** on PG14+, `pg_stat_statements`
distinguishes top-level queries from those called inside functions via the `toplevel`
boolean. The full uniqueness key is `(userid, dbid, queryid, toplevel)`. The side
table and all join conditions must include `toplevel` on PG14+, otherwise two
entries with the same `(queryid, dbid, userid)` but different `toplevel` values
are conflated, causing missed or incorrect sparse comparisons. Since PG14 is the
minimum supported version, `toplevel` is always present.

```sql
create unlogged table pgfr_record.statement_last_state (
    queryid   bigint  not null,
    dbid      oid     not null,
    userid    oid     not null,
    toplevel  boolean not null,  -- PG14+; part of PGSS uniqueness key
    calls     bigint  not null,
    sample_ts int4    not null,
    primary key (queryid, dbid, userid, toplevel)
) with (
    fillfactor = 70,                       -- leave room for HOT updates
    autovacuum_vacuum_scale_factor = 0.01, -- vacuum after 1% dead tuples
    autovacuum_analyze_scale_factor = 0.01
);
```

The table is updated every minute for up to 5,000 rows — 7.2M UPDATEs/day. Without
`fillfactor = 70`, these updates generate dead tuples on every page, recreating
the bloat problem on a smaller scale. With HOT-friendly fillfactor and aggressive
autovacuum, dead tuples are reclaimed within the same page without index updates.
Expected table size: ~few MiB at 5,000 rows.

The side table is strictly a sparse-comparison cache. It carries only
`(queryid, dbid, userid, toplevel, calls, sample_ts)` — nothing else. Readers
must never query it directly; all reads go through the partitioned history table.

**Collector flow each tick:**

1. Hash-join `pg_stat_statements` against `statement_last_state` (O(n), ~5,000-row table)
2. Insert changed rows into the daily partition
3. `TRUNCATE` + rebuild `statement_last_state` at daily partition boundary (see below);
   on non-boundary ticks, upsert changed rows using `INSERT ... ON CONFLICT DO UPDATE`

Cost is O(1) per queryid regardless of partition age.

**Upsert must use `INSERT ... ON CONFLICT DO UPDATE` — not DELETE + INSERT:**
HOT updates only occur when a tuple stays on the same heap page. A DELETE + INSERT
always writes a new tuple, defeating the fillfactor optimization and generating
dead tuples. Non-boundary upserts must use:

```sql
insert into pgfr_record.statement_last_state
    (queryid, dbid, userid, toplevel, calls, sample_ts)
values (...)
on conflict (queryid, dbid, userid, toplevel) do update
    set calls     = excluded.calls,
        sample_ts = excluded.sample_ts;
```

Only `calls` and `sample_ts` change — never the key columns — so HOT is always
eligible as long as no index covers `calls` or `sample_ts`.

**HOT contract — enforce via DDL comment:**

```sql
comment on table pgfr_record.statement_last_state is
    'HOT-sensitive: do NOT index mutable columns (calls, sample_ts). '
    'HOT updates require changed columns to be unindexed. '
    'See: https://github.com/NikolayS/pg-flight-recorder/blueprints/SPEC.md §5.2';
```

Add a pgTAP guard that asserts no index on this table covers `calls` or `sample_ts`.

**Insert condition:**

```sql
insert into pgfr_record.statement_snapshots (...)
select ...
from pg_stat_statements pss
left join pgfr_record.statement_last_state ls
    using (queryid, dbid, userid, toplevel)
where
    ls.queryid is null       -- first appearance (baseline or post-crash)
    or pss.calls > ls.calls  -- query was called
    or pss.calls < ls.calls; -- calls dropped: pg_stat_statements_reset() occurred
```

**Partition boundary guarantee and side table rebuild:** at the start of each new
day's partition, `TRUNCATE statement_last_state` and rebuild it fully from
`pg_stat_statements`. Do not use incremental upsert at the boundary — TRUNCATE +
INSERT ensures the side table is exactly aligned with current PGSS contents,
preventing stale entries for evicted queryids from accumulating over time.
(A queryid evicted from PGSS and never returning would otherwise sit in the side
table forever; a hash collision reusing that queryid would then get an incorrect
stale `calls` value.)

**Crash recovery:** after a crash, `statement_last_state` is empty (UNLOGGED).
`snapshot()` detects this on its first tick and calls `_rebuild_statement_last_state()`.
Use an advisory lock to prevent concurrent callers from both rebuilding simultaneously.
Note: `pg_try_advisory_xact_lock()` holds the lock for the entire transaction —
not just the rebuild phase. This is intentional: a human DBA manually running
`SELECT pgfr_record.snapshot()` during an incident will hit the skip condition
immediately and exit cleanly, leaving the pg_cron job to finish uninterrupted.

**Clean-restart desync trap:** UNLOGGED tables are only truncated during *crash*
recovery. On a *clean* shutdown (`pg_ctl stop`), the UNLOGGED table is flushed to
disk and retains its data on restart. If `pg_stat_statements.save = off` (or the
stats file is deleted), PGSS wakes up empty while `statement_last_state` still
holds large cumulative values — causing `pss.calls < ls.calls` for every query on
the next tick and a spurious cluster-wide "reset" event.

The emptiness check alone is insufficient. Also check whether PGSS has been reset
since the last stored `sample_ts`:

```sql
-- inside snapshot(), before the main collection:
declare
    v_pgss_reset timestamptz;
    v_last_sample_ts int4;
begin
    -- detect PGSS reset or clean restart with stats loss
    select stats_reset into v_pgss_reset from pg_stat_statements_info;
    select max(sample_ts) into v_last_sample_ts from pgfr_record.statement_last_state;

    if v_last_sample_ts is null  -- empty (crash recovery)
    or v_pgss_reset > (pgfr_record.epoch() + v_last_sample_ts * interval '1 second')
    then
        -- side table is stale or PGSS was reset since last sample
        if pg_try_advisory_xact_lock(hashtext('pgfr_last_state_rebuild')) then
            perform pgfr_record._rebuild_statement_last_state();
        else
            -- another session is rebuilding; skip this tick entirely
            -- record skip for observability (increment counter in snapshots parent row)
            return;
        end if;
    end if;
end;
```

The rebuild lock is intentionally held for the full `snapshot()` transaction.
If `snapshot()` latency grows (future regressions, slow systems), skip frequency
will increase proportionally — this is observable via the skip counter.

`_rebuild_statement_last_state()` must:

1. `TRUNCATE pgfr_record.statement_last_state`
2. `INSERT INTO statement_last_state SELECT ... FROM pg_stat_statements`
3. `ANALYZE pgfr_record.statement_last_state` — immediately lock in accurate
   statistics for the planner; do not rely on autovacuum to catch up after truncation

The rebuild causes one anomalous tick of higher write volume (~5,000 rows as "first
appearance") but is fully correct — no silent corruption, no external dependency.

**PGSS collection failure isolation:** the PGSS collection section must be wrapped
in its own exception handler within `snapshot()` so that a failure (extension not
loaded, shared memory error, view unavailable) does not prevent other collection
sections (table stats, index stats, WAL stats) from running on the same tick. If
`pg_stat_statements` is unavailable, skip the rebuild — do not TRUNCATE the side
table, as that would cause the next tick to treat everything as "first appearance"
when the extension returns.

**Reset detection:** when `calls` drops between snapshots, `pg_stat_statements_reset()`
was called (resets PGSS counters only — independent of `pg_stat_reset()` which resets
bgwriter/WAL/I/O stats). Always store the post-reset row — it marks the reset
boundary for readers.

Note: `pg_stat_statements_reset()` can target a specific `(userid, dbid, queryid)`
(partial reset). The `calls < last_calls` condition detects partial resets correctly.
For bulletproof detection, also check `stats_since` from `pg_stat_statements`
(PG14+, always available per §2 minimum version) — this gives a definitive signal
independent of counter arithmetic and handles the edge case where post-reset calls
accumulate back to the pre-reset value before the next tick.

**PGSS eviction:** when a queryid is evicted from PGSS to make room for a new one,
it disappears from the view. If it never reappears, it simply stops generating rows —
this is correct behavior. If it reappears later, it is treated as "first appearance"
and gets a fresh baseline. Readers must treat a gap in rows as "unknown activity"
during the eviction window, not "zero activity." Document this semantic contract
explicitly in reader function headers.

Additionally, track `pg_stat_statements_info.dealloc` (PG14+) — if the deallocation
counter increases between ticks, flag the snapshot as potentially incomplete.
Store this in the `snapshots` parent row so readers can warn consumers that
interval-activity queries spanning a deallocation event may undercount.

**`dealloc` is cluster-wide, not per-database:** `pg_stat_statements_info` is a
single cluster-level view. A query storm on database A that causes mass evictions
increments `dealloc` for all databases. A pg-flight-recorder instance on database B
will see the increment and flag its snapshot as incomplete — even though database B
lost zero queries. Reader function warnings must say **"cluster-level PGSS evictions
detected during this window"**, not "data for this database is missing." This
prevents operator panic on multi-tenant clusters.

**Expected reduction:** on a typical server with 5,000 tracked queries, 50–200
queries fire on any given minute tick. The sparse model inserts 50–200 rows
instead of 5,000 — a 25–100× reduction per tick. Over 30 days (assuming ~280
bytes/row based on schema analysis — to be confirmed by §9.2 baseline measurement):

| Scenario                               | Rows/day              | ~MiB/day | vs naive       |
|----------------------------------------|-----------------------|----------|----------------|
| Naive (full insert)                    | 7,200,000             | ~2,024   | baseline       |
| Sparse — heavy OLTP (200 active/tick)  | ~290,000              | ~81      | ~25× better    |
| Sparse — typical OLTP (50 active/tick) | ~75,000               | ~21      | ~96× better    |
| Sparse — idle (0 active/tick)          | 5,000 (baseline only) | ~1.4     | ~1,400× better |

### 5.3 Apply to `table_snapshots` and `index_snapshots`

`pg_stat_user_tables` exposes cumulative counters. A table that has not been
touched since the last snapshot has identical values.

**Insert condition:** store a new row only when any tracked counter changed.
The sentinel must cover all columns that can change independently — not just
activity counters. At minimum: `seq_scan`, `idx_scan`, `n_tup_ins`, `n_tup_upd`,
`n_tup_del`, `n_dead_tup`, `n_live_tup`, `last_vacuum`, `last_autovacuum`,
`last_analyze`, `last_autoanalyze`. On PG16+, also include `last_seq_scan` and
`last_idx_scan`. Any column omitted from the sentinel is silently not change-tracked
— this must be a conscious documented decision, not an oversight.

Same partition boundary guarantee applies: full baseline row per relation at the
start of each day's partition.

**Midnight baseline insert:** the partition boundary inserts a full baseline for
all tracked relations in one tick. At 10,000+ tables and 30,000+ indexes this is
~40,000 rows — a medium bulk insert that PostgreSQL completes in tens of milliseconds.
Do not spread this across ticks: spreading destroys the partition boundary guarantee
and makes reader reconstruction logic significantly more complex. If the circuit
breaker trips on the 00:00 tick, tune the breaker to allow higher latency tolerance
specifically for that tick rather than compromising the data model.

**`pg_stat_reset_single_table_counters(oid)` handling:** this function resets all
stats for a specific table (seq_scan, idx_scan, n_tup_ins, etc.) to zero. Since
the sparse sentinel detects "any tracked counter changed," a reset from nonzero to
zero is caught automatically — the values changed, so a row is stored. The only
edge case (all counters already zero before reset) produces no false behavior: if
nothing changed, there is nothing to record. No special handling required, but add
a pgTAP test confirming detection.

**Expected reduction:** the long tail of static tables (reference tables, infrequently
written application tables, system catalogs) produces no rows after the daily
baseline. Reduction: 3–10× vs naive model depending on table activity distribution.

### 5.4 What NOT to apply sparse storage to

| Table                          | Reason                                                                     |
|--------------------------------|----------------------------------------------------------------------------|
| `snapshots` (parent)           | Low volume (1 row/min), serves as the master timeline anchor               |
| `replication_snapshots`        | Low volume; replication state changes matter even when counters are stable |
| `vacuum_progress_snapshots`    | Only populated during active vacuum — already sparse by nature             |
| Archive and ring buffer tables | Written from ring flush or ring sampling — different collection path       |

---

## 6. Reader Functions for Sparse Data

With sparse storage, reader functions must reconstruct the full picture at any
requested timestamp. The storage model is invisible to the consumer — functions
handle reconstruction internally.

### 6.1 Partition boundary guarantee simplifies readers

Because every sparse table has a full baseline row at the start of each daily
partition, any point-in-time read needs to look back at most one partition
boundary. Reconstruction cost is O(log n) per queryid or relid — a single index
scan on `(queryid, dbid, userid, sample_ts DESC)`.

### 6.2 Reader patterns

Three read patterns cover all use cases. The sparse storage model is an
implementation detail — reader functions expose the same interface as before.

**Point-in-time state** — reconstruct the full state of all tracked objects at
any timestamp T. The partition boundary baseline guarantee means lookback is
bounded to one partition; no unbounded scan required.

**Interval activity** — determine what happened between T1 and T2. For cumulative
counters this means comparing the earliest and latest stored values within the
window. Reset events (counter drops) must be detected and handled at the boundary
rather than silently producing negative deltas.

**Change history** — enumerate when a value changed and what it changed to.
With sparse storage every stored row is already a change event, so this pattern
requires no special logic beyond a time-bounded index scan.

### 6.3 Key constraint: function-level JIT disable

All reader functions must disable JIT. Do not use `SET jit = off` inside the
function body — this leaks into the caller's session and may degrade subsequent
analytical queries. Instead, use the function-level `SET` clause which scopes
the setting strictly to the function's execution and reverts automatically on return:

```sql
create or replace function pgfr_record.get_statement_history(...)
returns ...
language sql
set jit = off
as $$ ... $$;
```

This guarantees JIT overhead does not affect the first call in a fresh session
(common during incidents) without contaminating the caller's session state.

PostgreSQL propagates function-level `SET` variables to nested calls within the
same transaction context, so inner functions called by reader functions inherit
`jit = off`. However, dynamically executed strings via `EXECUTE format(...)` do
not inherit function-level settings — they plan in the current session context.
If reader functions use `EXECUTE` (as ring buffer readers do), ensure the dynamic
query string is reached only after the top-level reader function (with `SET jit = off`)
has been entered — not called from outside that context. Set `jit = off` explicitly
at the top-level API boundary before any `EXECUTE` calls to guarantee coverage.

---

## 7. Proposed Solution: N Daily Partitions, No DELETE

### 7.1 Partition structure

Partition every table by day using `partition by range (sample_ts)`. Retention =
N days = N partitions. Drop the oldest partition when it falls outside the
retention window. No DELETE. No dead tuples. No autovacuum pressure from retention.

```sql
create table pgfr_record.statement_snapshots (
    snapshot_id  bigint not null,  -- bigint: upstream uses integer (SERIAL), see Q5
    sample_ts    int4 not null,    -- seconds since pgfr_record.epoch(); see Q6
    queryid      bigint not null,
    ...
) partition by range (sample_ts);  -- see Q6 for partition key discussion

create table pgfr_record.statement_snapshots_2026_02_26
    partition of pgfr_record.statement_snapshots
    for values from (...) to (...);  -- int4 bounds derived from epoch + date
```

The `sample_ts` column is an `int4` offset from a fixed installation epoch —
the same approach used by pg_ash. `int4` is 4 bytes vs 8 bytes for `timestamptz`,
saving 4 bytes/row. At 216M naive rows that is ~824 MiB saved on `statement_snapshots`
alone, before any sparse optimization.

**Epoch function (borrowed from pg_ash):**

```sql
-- WARNING: must never change after installation — all sample_ts values are
-- seconds offset from this point. Changing it corrupts all timestamps.
create or replace function pgfr_record.epoch()
returns timestamptz immutable language sql as
$$select '2026-01-01 00:00:00+00'::timestamptz$$;
```

**Reconstruct timestamptz from sample_ts:**

```sql
pgfr_record.epoch() + sample_ts * interval '1 second'
```

**Partition key:** PostgreSQL range partitioning works on `int4` — no need for
`timestamptz` as the partition key. Partition bounds are computed as:

```sql
-- for date 2026-02-26, always explicit UTC to avoid session timezone drift:
extract(epoch from '2026-02-26 00:00:00+00'::timestamptz - pgfr_record.epoch())::int4
```

All date-to-epoch conversions must use explicit UTC offsets (`+00`). If `_ensure_partition()`
runs in a pg_cron session with a non-UTC timezone, implicit casts will shift the
partition boundary. Enforce with `SET LOCAL timezone = 'UTC'` at function entry
or always use `AT TIME ZONE 'UTC'` explicitly.

This makes each child table self-contained for retention — no join back to the
parent required, and no `timestamptz` stored in any hot row.

**Index definitions:** indexes must be created by `_ensure_partition()` for each
new partition automatically. At minimum for `statement_snapshots`:

```sql
create index on statement_snapshots_YYYY_MM_DD (queryid, dbid, userid, sample_ts desc);
```

Consider a covering index adding `calls` to allow index-only scans for the sparse
comparison (avoids heap fetch for the most common access pattern).

Additionally, evaluate a **BRIN index on `sample_ts`** as a secondary index for
pure time-range queries ("show me everything from the last hour"). Within a daily
partition, rows are inserted in `sample_ts` order — natural correlation makes BRIN
highly effective. A BRIN index is a few KiB vs tens of MiB for a B-tree.

The default `pages_per_range = 128` (1 MiB of heap) is too coarse for sparse
inserts: at 50–200 rows/tick, 1 MiB spans several hours of data, causing a 5-minute
query to scan hours of heap blocks. Tune explicitly:

```sql
create index on statement_snapshots_YYYY_MM_DD
    using brin (sample_ts) with (pages_per_range = 8);
```

Validate correlation before relying on BRIN — long transactions crossing midnight
can disturb insertion order:

```sql
select correlation from pg_stats
where tablename = 'statement_snapshots_YYYY_MM_DD' and attname = 'sample_ts';
-- should be close to 1.0; if < 0.9, BRIN effectiveness degrades
```

The B-tree on `(queryid, dbid, userid, sample_ts DESC)` remains necessary for
point-in-time reconstruction. These two indexes serve completely non-overlapping
execution paths: the planner will strongly prefer the B-tree for any query that
filters by `queryid` AND time range; the BRIN serves global time-range aggregates
only ("total calls in the last hour"). Both are justified at very low storage cost.

`pages_per_range = 8` is a starting point — tune based on observed rows/minute.
For very sparse workloads (< 50 rows/tick) a larger range may be appropriate;
for dense workloads the default 128 wastes selectivity. Benchmark both in Phase 1.

**int4 horizon:** with a 2026-01-01 epoch, `int4` seconds overflow in approximately
2094. This is not an imminent risk, but future engineers must know:

- the epoch must never change after installation (corrupts all stored timestamps)
- replicas installed later use the same epoch from the primary
- a migration path (new epoch column, dual-read period) must be planned before 2090
Document this prominently in the install notes.

### 7.2 Partition pre-creation and drop

```sql
-- create tomorrow's partition (run nightly via pg_cron):
select pgfr_record._ensure_partition('statement_snapshots', current_date + 1);

-- truncate partitions outside the retention window (run nightly):
select pgfr_record.truncate_old_partitions();
```

`_ensure_partition()` is idempotent — safe to call multiple times for the same
date. Additionally, `snapshot()` must call `_ensure_partition()` for the current
tick's `sample_ts` at runtime as a safety net — the nightly pre-create is an
optimization, but a cron failure, clock skew, or long transaction crossing midnight
can cause an INSERT to fail with "no partition for value." Runtime ensure is cheap
and idempotent; make it the correctness guarantee.

**TRUNCATE old partitions — do not DROP them:**
Rather than dropping expired partitions (which requires DETACH + DROP and the
associated locking complexity, dblink dependency, and orphan tracking), simply
`TRUNCATE` them. The partition remains attached and visible to the planner, but
contains no rows. Storage is reclaimed immediately. The planner prunes empty
partitions on any time-bounded query — no performance cost.

Benefits over DROP:

- Runs entirely inside a plain PL/pgSQL function — no dblink, no external orchestrator
- No DETACH CONCURRENTLY transaction-context trap
- No orphaned detached tables to track
- No two-phase state machine needed

**`TRUNCATE` locking — correct framing:**
`TRUNCATE` acquires `ACCESS EXCLUSIVE` on the target partition — the same lock
level as DROP. The advantage is narrower scope: unlike DROP, TRUNCATE does not
modify the parent table's `pg_inherits` catalog entry or invalidate the parent's
relcache. Concurrent `snapshot()` inserts into the current partition acquire locks
only on their target partition and are unaffected.

A sloppy analytical query against the parent table *without* a time bound will
prevent the planner from pruning, causing it to acquire `ACCESS SHARE` on all
child partitions including the one being truncated. Always wrap TRUNCATE calls in a short `lock_timeout`. PostgreSQL's lock queue is
FIFO: while the TRUNCATE waits for `ACCESS EXCLUSIVE`, all subsequent reader
queries queue behind it — creating a system-wide stall for the duration of the
timeout. Use an aggressive timeout for background GC:

```sql
set local lock_timeout = '50ms';  -- not 2s: FIFO queue stalls all readers
truncate pgfr_record.statement_snapshots_2026_01_01;
```

If the timeout fires, skip and retry next hour. The system catches up automatically
once the blocking query completes — lag does not accumulate permanently. Under persistent lock contention
(a pathological long-running query holding `ACCESS SHARE` for hours), expired
partitions will lag behind the retention target. This is intentional:
**retention is best-effort under persistent lock contention** — never stalling
the collection loop is the higher priority.

**Partition definition accumulation — two-tier approach:**
Partition definitions accumulate over time. At 365-day retention running for 2
years, you reach ~7,300 partitions across 10 tables — approaching the Q8 safety
threshold. Use a two-tier approach:

- **Fast-path (nightly):** `truncate_old_partitions()` — empties expired partitions, O(1) per partition, no catalog modification
- **Slow-path (monthly):** `drop_ancient_partitions()` — drops empty partitions older than `2 × retention_snapshots_days`, keeping total partition count permanently bounded

The slow-path targets only *empty* (already truncated) partitions that have been
empty for a full extra retention cycle. These have no concurrent readers. A plain
`DROP TABLE` with `lock_timeout = '2s'` suffices — no DETACH CONCURRENTLY needed
since the table has been empty for weeks.

The monthly cadence is a default. Operators on high-retention setups (365 days ×
many tables) or multi-tenant fleets may tune this to weekly or cap drops per run
to avoid bursty catalog churn. Document the cadence as a configurable parameter.

```sql
-- drop_ancient_partitions(): run monthly via pg_cron (cadence is configurable)
-- targets empty partitions with upper bound older than 2× retention
set local lock_timeout = '2s';
drop table if exists pgfr_record.statement_snapshots_ancient;
-- on lock_not_available: skip and try next run
```

**Use pg_catalog to identify eligible partitions — not suffix parsing:**
Both `truncate_old_partitions()` and `drop_ancient_partitions()` must identify
partitions via `_partition_inventory()` (see below), not by parsing `_YYYY_MM_DD`
suffixes from table names.

**`_partition_inventory()` — shared catalog query:**

```sql
create or replace function pgfr_record._partition_inventory()
returns table (
    parent_table   text,
    partition_name text,
    bound_start    int4,
    bound_end      int4,
    is_expired     boolean,  -- upper bound < retention cutoff sample_ts
    is_ancient     boolean,  -- upper bound < 2× retention cutoff sample_ts
    is_empty       boolean   -- pg_relation_size(oid) = 0 (authoritative after TRUNCATE; do NOT use reltuples which lags until next ANALYZE)
) language sql stable as $$
    select
        parent.relname::text,
        child.relname::text,
        (pg_catalog.pg_get_expr(child.relpartbound, child.oid)
            -- parse lower int4 bound from expression)::int4,
        (pg_catalog.pg_get_expr(child.relpartbound, child.oid)
            -- parse upper int4 bound from expression)::int4,
        -- is_expired, is_ancient, is_empty computed from bounds and pg_class.reltuples
        ...
    from pg_catalog.pg_inherits i
    join pg_catalog.pg_class child  on child.oid = i.inhrelid
    join pg_catalog.pg_class parent on parent.oid = i.inhparent
    join pg_catalog.pg_namespace n  on n.oid = child.relnamespace
    where n.nspname = 'pgfr_record';
$$;
```

Used by `truncate_old_partitions()`, `drop_ancient_partitions()`, and
`partition_gc_health`. Exact bound-parsing SQL to be finalized in implementation.

**`_partition_inventory()` bound parsing is the highest long-term fragility risk:**
`pg_get_expr(relpartbound, oid)` returns a text representation whose format is not
guaranteed stable across major PostgreSQL versions. Whitespace variations, syntax
nuances for LIST/RANGE, and future changes can silently break parsing. Mitigations:

- Use defensive regex with strict assertions (fail loudly on unexpected format)
- Add runtime assertions at function entry:
  - verify parent is RANGE partitioned (`pg_partitioned_table.partstrat = 'r'`)
  - verify single partition key column (`pg_partitioned_table.partnatts = 1`)
  - verify key column type is `int4` (`pg_attribute.atttypid = 23`)
  - if any assertion fails: raise exception immediately — silent corruption is worse than a loud failure
- Add pgTAP tests that validate bound parsing on each supported PG version
- Document explicitly: **this function assumes single-column RANGE partitioning on
  `int4`**. Multi-column or non-int4 partition keys are not supported.

**`_ensure_partition()` must be O(1) on the happy path:**
On every tick, `snapshot()` calls `_ensure_partition()` as a runtime safety net.
The function must open with a catalog existence check that returns immediately if
the partition already exists — no DDL, no lock acquisition:

```sql
if exists (select 1 from pg_catalog.pg_class ...) then return; end if;
-- only reaches DDL if partition is missing
```

This makes the common case a single catalog lookup with no side effects.

**`partition_gc_health` view for operator visibility:**

```sql
create or replace view pgfr_record.partition_gc_health as
select
    parent_table,
    count(*)                                                as total_partitions,
    count(*) filter (where is_expired and not is_empty)     as pending_truncation,
    count(*) filter (where is_expired and is_empty
                     and not is_ancient)                    as truncated_recent,
    count(*) filter (where is_ancient and is_empty)         as pending_drop,
    max(bound_end) filter (where is_expired and not is_empty) as oldest_pending_truncation
from pgfr_record._partition_inventory()
group by parent_table;
```

Exposes pending truncations, recently truncated, and ancient partitions awaiting
the monthly slow-path drop.

### 7.3 Hot ring buffers: TRUNCATE rotation

The ring buffers (`wait_samples_ring`, `activity_samples_ring`, `lock_samples_ring`)
have a different but related problem: UPDATE-based overwrite on UNLOGGED tables
generates dead tuples on every sample cycle. The fix is 3-partition TRUNCATE
rotation with INSERT-only writes — identical to the pg_ash approach.

```
partition_0 (previous) | partition_1 (current, inserting) | partition_2 (truncated, next)
```

At rotation: advance the current slot, TRUNCATE the "next" partition. Zero dead
tuples. No semantic change to the ring window or reader behavior.

**Reader views must exclude the "next" partition:** `TRUNCATE` requires
`ACCESS EXCLUSIVE` on the target partition. A concurrent `SELECT` that touches
all three partitions acquires `ACCESS SHARE` on each — including the one being
truncated — blocking the TRUNCATE and stalling the collector.

Do not rely on `sample_ts`-range pruning to exclude the "next" partition: if the
rotation metadata (which partition is "next") is read at runtime from a table, the
planner does not know the bounds at plan time and will not prune. Instead, reader
functions must query the `previous` and `current` partitions by name, assembled
dynamically and executed via `EXECUTE` in PL/pgSQL:

```sql
-- reader function: query only known-safe partitions by name
execute format(
    'select ... from pgfr_record.%I union all select ... from pgfr_record.%I',
    v_current_partition, v_previous_partition
);
```

This guarantees no lock on the "next" partition regardless of planner behavior.
`EXECUTE` is chosen deliberately for lock safety over plan caching — the slight
CPU overhead per call is the correct trade-off. Do not "optimize" this back to a
static query.

### 7.4 Scope of partition-based retention

All tables receive the same treatment. Phases determined by volume and impact:

| Table                                        | Fix                                           | Phase |
|----------------------------------------------|-----------------------------------------------|-------|
| `statement_snapshots`                        | Sparse insert + daily partitions              | 1     |
| `config_snapshots`                           | Daily partitions (sparse insert already done) | 1     |
| `table_snapshots`, `index_snapshots`         | Sparse insert + daily partitions              | 2     |
| `snapshots`, `replication_snapshots`, others | Daily partitions                              | 2     |
| Archive tables                               | Daily partitions                              | 3     |
| Hot ring buffers                             | TRUNCATE rotation                             | 3     |

---

## 8. Retention Model

Each data tier has one canonical retention config key. N days retention = N daily
partitions, oldest dropped nightly.

| Config key                 | Default | Min | Max | Covers                                         |
|----------------------------|---------|-----|-----|------------------------------------------------|
| `retention_snapshots_days` | 30      | 1   | 365 | All snapshot-tier tables                       |
| `retention_archive_days`   | 7       | 1   | 90  | Archive and aggregate tables                   |
| `retention_hot_hours`      | 4       | 2   | 168 | Hot ring — rotation period, not partition drop |

Old config keys (`aggregate_retention_days`, `archive_retention_days`,
`retention_samples_days`) remain as deprecated aliases until removed in a later
phase.

**Logical replication warning:** `TRUNCATE` is replicated by logical replication
(`pgoutput` and compatible plugins). If pg-flight-recorder tables are published to
a downstream data warehouse (ClickHouse, Snowflake, Redshift) for long-term
retention, the nightly `truncate_old_partitions()` will replicate downstream and
wipe the warehouse history. Users streaming telemetry via logical replication must
exclude `TRUNCATE` from publication parameters:

```sql
create publication pgfr_telemetry_pub
    for all tables in schema pgfr_record
    with (publish = 'insert, update, delete');  -- truncate intentionally omitted
```

Document this prominently in the installation guide.

---

## 9. Benchmarking and Testing

The benchmark suite has two goals: prove correctness (reader output is identical
to the old schema for any given time window) and prove superiority (zero bloat,
orders-of-magnitude storage reduction) under realistic and extreme conditions.

Both old and new schemas run side by side on identical hardware with identical
workloads. Results are published to `benchmarks/` in the repository.

See also: https://github.com/dventimisupabase/pg-flight-recorder/pull/13 for
prior benchmarking context.

### 9.1 Test environment

Dedicated server — AMD EPYC or equivalent, 8 vCPU, 16 GiB RAM. No shared or
burstable instances.

```
shared_buffers = '4GB'
max_connections = 200
autovacuum = on
autovacuum_vacuum_cost_delay = 2ms
pg_stat_statements.max = 5000       -- the PostgreSQL default; non-negotiable
```

PostgreSQL 17, pg_cron 1.6.

### 9.2 Baseline measurement — actual row counts and sizes (run first)

**Goal:** Replace the estimated numbers in Section 3 with observed values from
the benchmark environment. All figures in the storage analysis table are currently
derived from schema inspection and row-count arithmetic. They must be validated
against a running installation before any optimization work begins.

Run pg-flight-recorder at default configuration for 24 hours, then measure:

```sql
-- Actual row counts
select
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    pg_size_pretty(pg_relation_size(relid))       as heap_size,
    pg_size_pretty(pg_total_relation_size(relid)) as total_size,
    pg_relation_size(relid) / nullif(n_live_tup, 0) as bytes_per_row
from pg_stat_user_tables
where schemaname = 'pgfr_record'
order by pg_total_relation_size(relid) desc;
```

```sql
-- Collection latency per section (from collection_stats)
select
    section_name,
    avg(duration_ms)  as avg_ms,
    max(duration_ms)  as max_ms,
    count(*)          as samples
from pgfr_record.collection_stats
where captured_at > now() - interval '1 hour'
group by section_name
order by avg_ms desc;
```

```sql
-- Actual rows inserted per hour (run after 24h of collection, against current schema)
select
    date_trunc('hour', s.captured_at) as hour,
    count(*) as rows_inserted
from pgfr_record.statement_snapshots ss
join pgfr_record.snapshots s on s.id = ss.snapshot_id
group by 1
order by 1;
```

Record for each table:

- Actual rows after 24h
- Actual bytes/row (heap_size / n_live_tup)
- Actual rows inserted per tick (from collection stats or direct count)

Update the Section 3 table with observed values before proceeding to any
optimization benchmarks. The estimates there are based on schema analysis;
real numbers may differ — especially `bytes_per_row` for TOAST-heavy columns
like `query_preview TEXT` in `statement_snapshots`.

### 9.3 Sparse storage reduction benchmark (Phase 1 focus)

**Goal:** Quantify how much sparse collection reduces row count vs the naive
full-insert model. The benchmark must use `pg_stat_statements.max = 5000` —
this is where the reduction is most dramatic and most representative.

**Setup:** generate exactly 5,000 distinct queryids to fill `pg_stat_statements`:

```bash
python3 -c "
for i in range(1, 5001):
    print(f'SELECT {i} AS n;')
" > /tmp/fill_pgss.sql

psql -f /tmp/fill_pgss.sql postgres > /dev/null
psql -c "select count(*) from pg_stat_statements;"
-- expected: 5000
```

Run under four workload profiles, each for 24 hours:

| Profile                  | Active queries per tick | Expected rows/tick (sparse)     | vs naive (5,000/tick)             |
|--------------------------|-------------------------|---------------------------------|-----------------------------------|
| Idle                     | 0                       | 5,000 (baseline only, once/day) | ~99.9% reduction                  |
| Typical OLTP             | ~50                     | ~50                             | ~99% reduction                    |
| Heavy OLTP               | ~200                    | ~200                            | ~96% reduction                    |
| Adversarial (all active) | ~5,000                  | ~5,000                          | ~0% — proves graceful degradation |

The adversarial profile confirms the sparse model never performs worse than naive.
The `statement_last_state` hash join overhead must not add unacceptable latency —
measure on the adversarial tick where all 5,000 rows require an upsert.

**Measure every hour:**

```sql
select
    'new (sparse)' as schema,
    date_trunc('hour', pgfr_record.epoch() + sample_ts * interval '1 second') as hour,
    count(*) as rows_inserted
from pgfr_record.statement_snapshots
group by 2
union all
select
    'old (naive)',
    date_trunc('hour', s.captured_at),
    count(*)
from pgfr_record_old.statement_snapshots ss
join pgfr_record_old.snapshots s on s.id = ss.snapshot_id
group by 2
order by 1, 2;
```

### 9.4 Simulated long-run bloat benchmark

**Goal:** Show what happens to the old schema under sustained operation across
multiple retention cycles — the scenario that causes production bloat — and confirm
the new schema is immune.

Real 30-day runs are impractical. Simulate by compressing time: short retention
window (1 hour) with continuous `snapshot()` + `cleanup()` in a loop for 2 hours
= 2 full retention cycles.

```sql
update pgfr_record.config set value = '0.04' where key = 'retention_snapshots_days';
-- 0.04 days ≈ 1 hour retention
```

```bash
# old schema:
pgbench -c 1 -j 1 -T 7200 \
  -f <(echo "select pgfr_record.snapshot(); select pgfr_record.cleanup();") postgres

# new schema:
pgbench -c 1 -j 1 -T 7200 \
  -f <(echo "select pgfr_record.snapshot(); select pgfr_record.truncate_old_partitions();") postgres
```

Measure every 15 minutes:

```sql
select
    now() as measured_at,
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    pg_size_pretty(pg_total_relation_size(relid)) as total_size
from pg_stat_user_tables
where schemaname in ('pgfr_record', 'pgfr_record_old')
  and relname like '%statement%'
order by schemaname, relname;
```

Expected:

| Metric                     | Old schema (DELETE) | New schema (partition TRUNCATE) |
|----------------------------|---------------------|---------------------------------|
| `n_dead_tup` after cleanup | = rows deleted      | 0 always                        |
| Heap size trend            | Growing             | Flat                            |
| Autovacuum runs per hour   | Many                | 0 from retention                |
| Cleanup duration trend     | Growing with bloat  | Constant                        |

### 9.5 Extreme bloat: autovacuum disabled

The real production failure mode: all autovacuum workers (default: 3) occupied
with other tables — common during bulk loads, post-maintenance, or on schemas with
high update churn. When no worker is available, the ring buffer and snapshot tables
accumulate bloat without bound.

```sql
alter table pgfr_record_old.statement_snapshots set (autovacuum_enabled = false);
```

Run the same 2-hour simulation (§9.4). Expected: heap grows unboundedly in the old
schema (2–5× live data size after 2 hours). New schema: zero dead tuples, no heap
growth beyond live data — partition TRUNCATE has no dependency on autovacuum at all.

### 9.6 Cleanup duration scaling

Measure at three data volumes: 1 day, 7 days, 30 days of accumulated data.

Expected scaling:

| Volume  | Old schema DELETE | New schema TRUNCATE |
|---------|-------------------|---------------------|
| 1 day   | ~500 ms           | < 50 ms             |
| 7 days  | ~3 s              | < 50 ms             |
| 30 days | ~15–30 s          | < 50 ms             |

Partition DROP is O(1) with respect to row count. DELETE is O(n).

### 9.7 Cleanup impact on concurrent `snapshot()` latency

A large DELETE holds a relation lock and generates WAL, which can cause concurrent
`snapshot()` calls to wait. Run both operations concurrently and capture `snapshot()`
durations from `collection_stats` before, during, and after cleanup.

Expected for old schema: latency spike during DELETE. Expected for new schema:
`truncate_old_partitions()` is near-instantaneous and `snapshot()` is unaffected.

### 9.8 `snapshot()` latency regression test

Confirm no regression in collection latency after migration. Run 50 calls, record
median and p99. Expected: no regression — the sparse insert adds one hash join
against `statement_last_state` (~5,000 rows, UNLOGGED, fully cached) per tick.
This must complete in under 5 ms at 5,000 queryids.

### 9.9 Reader correctness and partition pruning

**Correctness:** for any time window, reader output must be identical between old
and new schema. Verify for point-in-time reads, interval activity, and edge cases
(reset events, first and last row of a partition).

**Partition pruning:** `now()` is stable within a transaction and `epoch()` is
IMMUTABLE, so the planner evaluates the bound at plan time and prunes correctly
in the common case. The real risk is prepared statements — a cached plan captures
the bound at prepare time, making it stale for subsequent executions. Reader
functions must pass time bounds as parameters rather than recomputing inside the
query body when used via prepared statements.

Verify pruning occurs at plan time via `EXPLAIN` (without `ANALYZE`):

```sql
explain
select count(*)
from pgfr_record.statement_snapshots
where sample_ts > extract(epoch from now() - interval '1 hour' - pgfr_record.epoch())::int4;
-- expect: "Partitions selected: 1 out of N" in the plan, not just at execution
```

Also verify `enable_partition_pruning = on` (default, but document the assumption).

Verify pruning under both custom and generic plan paths. When `plan_cache_mode = auto`
and PostgreSQL decides a generic plan is cheaper, partition pruning may degrade.
Test explicitly: prepare the time-bounded query, execute it enough times to trigger
generic plan selection, and confirm pruning still occurs.

Old schema has no partitioning — every time-bounded query scans the full table.

### 9.10 Reset handling

Two independent reset functions must be tested:

**`pg_stat_statements_reset()`** — resets PGSS counters. `calls` drops to zero
for affected queryids. The sparse insert condition detects this via `pss.calls < l.calls`
and stores the post-reset baseline row.

**`pg_stat_reset()`** — resets global stats (`pg_stat_bgwriter`, `pg_stat_wal`,
`pg_stat_io`, etc.) tracked in the `snapshots` parent table. Counters in those
columns drop to zero. The parent table is not sparse (1 row/min regardless), but
reader functions computing deltas must detect and handle the reset boundary.

For each: trigger 10 resets over 1 hour while collecting. Verify:

- Reader functions return non-negative delta values across a reset boundary
- Reset events are correctly identified and surfaced (not silently dropped)
- No negative `calls_delta` or counter-delta values reach callers

### 9.11 WAL volume benchmark

WAL reduction is one of the strongest arguments for the partition approach.
Measure all three retention methods for completeness — DELETE, TRUNCATE, and DROP
(the latter used by the monthly `drop_ancient_partitions()` slow path).

```sql
-- measure WAL generated by each retention operation:
select pg_current_wal_lsn() as before_lsn;
-- run cleanup (DELETE / TRUNCATE / DROP)
select pg_current_wal_lsn() as after_lsn;
-- delta = WAL bytes generated
```

On PG14+ use `pg_stat_wal` for cumulative WAL stats.

Expected WAL profile:

- **DELETE** of 7.2M rows: hundreds of MiB (one WAL record per row)
- **TRUNCATE** of a partition: few KiB (single WAL record for relfilenode change + fork metadata) — not near-zero like DROP, but orders of magnitude less than DELETE. The TRUNCATE trade-off is intentional: slightly more WAL than DROP in exchange for drastically simpler operations (no DETACH, no dblink, no orphan tracking).
- **DROP** of an empty partition (monthly slow-path): kilobytes (catalog change only)

On replicas, the DELETE vs TRUNCATE/DROP difference is the dominant replication lag
factor during cleanup windows. Quantify replica apply lag (`pg_last_xact_replay_timestamp()`)
under each method.

### 9.12 High queryid churn benchmark

Common in ORM workloads with literal values in queries (generates new normalized
queryids constantly, saturating PGSS and causing high eviction rates).

**Setup:** continuously generate new distinct queryids at a rate that keeps PGSS
near capacity and eviction rate high. Measure:

- Sparse insert effectiveness (does last-state table stay consistent through evictions?)
- `statement_last_state` correctness across eviction/reappearance cycles
- Partition growth rate vs baseline expectation

**Pass/fail criteria:**

- `statement_last_state` row count never exceeds `pg_stat_statements.max` + 10%
  (accounting for in-flight evictions between TRUNCATE cycles)
- No assertion failures or constraint violations during the run
- Sparse insert rate remains within 2× of expected rate for measured active-queries-per-tick
- No negative delta values surfaced by reader functions across any eviction boundary

This is the real-world stress case that adversarial-active benchmarks miss.

### 9.13 pgTAP regression suite

All existing tests must pass without modification. New tests for Phase 1:

- `_ensure_partition()` is idempotent
- `snapshot()` calls `_ensure_partition()` at runtime (correctness guarantee)
- `snapshot()` routes to the correct daily partition
- `truncate_old_partitions()` uses `pg_inherits`/`pg_class` + partition bounds, not suffix parsing
- `truncate_old_partitions()` TRUNCATEs exactly the partitions outside the retention window
- `truncate_old_partitions()` leaves partition definitions intact — no DROP, no DETACH
- Sparse insert: rows skipped when `calls` unchanged; rows stored when `calls` increases
- `statement_last_state` correctly reflects latest state after each tick
- `statement_last_state` crash recovery: TRUNCATE side table, run `snapshot()`, confirm exactly one baseline row per queryid, no duplicates
- `statement_last_state` crash recovery uses advisory lock — concurrent callers don't double-rebuild
- `statement_last_state` upsert uses `INSERT ... ON CONFLICT DO UPDATE` (not DELETE+INSERT) — verify via `pg_stat_user_tables.n_dead_tup` remains bounded
- `statement_last_state` HOT contract: no index covers `calls` or `sample_ts`
- `statement_last_state` daily TRUNCATE+rebuild keeps row count ≤ `pg_stat_statements.max`
- `_rebuild_statement_last_state()` calls `ANALYZE` immediately after INSERT
- `toplevel` column included in composite key; two entries differing only in `toplevel` tracked independently
- Partition boundary baseline: first row of each day covers all active queryids
- `n_dead_tup = 0` and `n_live_tup = 0` on truncated partitions
- truncated partitions still attached, pruned correctly by time-bounded queries
- `drop_ancient_partitions()` drops only empty partitions older than 2× retention
- `partition_gc_health` view returns correct counts: pending-truncation, truncated-recent, pending-drop
- `_ensure_partition()` returns immediately (O(1)) when partition already exists — no DDL executed
- `pg_stat_reset_single_table_counters()` reset detected by table_snapshots sparse sentinel
- ring buffer reader functions query partitions by name via EXECUTE — never touch "next" partition
- Reader output matches old schema for the same time window
- Partition pruning confirmed via `EXPLAIN` (no `ANALYZE`) at planning time — both custom and generic plan paths
- Partition creation with non-UTC session timezone produces identical bounds to UTC session
- JIT disable is function-level (not session-leaking) — verify via `pg_stat_statements`
- Ring buffer reader views never acquire locks on the "next" (truncating) partition

---

## 10. Open Questions

**Q1: Drop FK constraints between time-series tables.**
If `snapshots` is partitioned in Phase 2 and a partition is dropped, PostgreSQL
will execute a cascading DELETE against all child tables before the partition can
be dropped — generating millions of dead tuples and defeating the Zero Bloat
objective entirely. Recommendation: drop all FK constraints between time-series
tables. In a continuous telemetry system, an orphaned child row is a minor
filterable anomaly; an autovacuum death spiral from a cascade is catastrophic.
Enforce integrity at the collection layer and rely on aligned `sample_ts` partition
boundaries for clean retention.

**Q2: Migration for existing installations. ✅ RESOLVED — implemented in `pgfr_record/migrate_phase1.sql` (Issue #10)**

**Q2b: Reader functions for v2 partitioned tables. ✅ RESOLVED — implemented in `pgfr_analyze/install.sql` (Issue #11)**

`pgfr_analyze` now ships v2-native reader functions that query `statement_snapshots_v2`,
`table_snapshots_v2`, and `index_snapshots_v2` directly via `int4 sample_ts` range
predicates, enabling partition pruning without joining through the `snapshots` table:

- `pgfr_analyze.v2_time_range(p_start, p_end)` — helper: converts `timestamptz` bounds
  to `int4 sample_ts` offsets via `pgfr_record.epoch()`.
- `pgfr_analyze.statement_activity_v2(p_start, p_end[, limit])` — top queries by
  `total_exec_time` delta.
- `pgfr_analyze.table_activity_v2(p_start, p_end[, limit])` — tables by modification
  rate (`n_tup_ins + n_tup_upd + n_tup_del` delta).
- `pgfr_analyze.index_activity_v2(p_start, p_end[, limit])` — indexes by `idx_scan`
  delta.

All three reader functions call `SET LOCAL jit = off` at entry (per §6 requirements).
Existing `statement_compare()`, `table_compare()`, `table_hotspots()`,
`index_efficiency()`, and `unused_indexes()` are untouched (backwards compatible).

The migration approach: instead of dual-write, rename old plain tables to `_legacy`
suffix and create backwards-compatible views so existing SELECT queries continue to
work unmodified. Old data is preserved — nothing is deleted.

**Migration function:** `pgfr_record.migrate_to_v2()` — run once after installing
the new `pgfr_record/install.sql`. Idempotent: safe to call multiple times.

**What it does (in order):**

1. Checks that v2 tables exist (`statement_snapshots_v2`, `table_snapshots_v2`,
   `index_snapshots_v2`) — raises ERROR with clear instructions if not found
2. Renames old plain tables to `_legacy` suffix (skips if already renamed):
   - `statement_snapshots` → `statement_snapshots_legacy`
   - `table_snapshots` → `table_snapshots_legacy`
   - `index_snapshots` → `index_snapshots_legacy`
3. Creates backwards-compat views: `statement_snapshots` (and equivalents) now
   point to the `_legacy` table — existing monitoring dashboards and tools keep working
4. Returns a text summary of all actions taken

**Cutover checklist (ordered — do not skip steps):**

1. Install the new `pgfr_record/install.sql` (creates v2 tables)
2. Run `SELECT pgfr_record.migrate_to_v2();` — verifies v2 tables, renames old tables
3. Verify backwards-compat views work: `SELECT count(*) FROM pgfr_record.statement_snapshots;`
4. Verify new v2 tables are receiving data from the collector
5. After ≥ 1 full retention cycle of v2 data, drop `_legacy` tables if storage is urgent
   (or leave them as a historical archive — they contain no live data)

**Rollback:** rename `_legacy` tables back to their original names and drop the views.
Old data is fully preserved.

**Dual-write strategy (from earlier SPEC version) is superseded** by this rename
approach. The rename is safer: no risk of duplicate data, no config flag to toggle,
no 2× storage cost. The only tradeoff is a brief maintenance window to run the
rename — which is a single metadata operation with no data movement.

**Q3: Partition pruning with dynamic bounds.**
`now()` is stable within a transaction and `epoch()` is IMMUTABLE — the planner
evaluates these at plan time and prunes correctly in the common case (ad-hoc queries
and PL/pgSQL functions). The real risk is prepared statements: a cached plan captures
the bound at prepare time, making it stale across executions. Reader functions using
prepared statements must pass time bounds as parameters. Verify correct pruning in
pgTAP via `EXPLAIN` (without `ANALYZE`) — see §9.9.

**Q4: Managed provider compatibility.**
Partitioned tables, `TRUNCATE`, and pg_cron are supported on RDS, Cloud SQL,
Supabase, and Neon. The daily partition pre-creation and nightly truncation jobs
require pg_cron scheduling rights. No dblink, no DROP TABLE on partitions, no
superuser required for partition management after initial install.

**Q5: `snapshot_id` integer overflow and Phase 2 sequence migration.**
The upstream `snapshots` table uses `SERIAL` (`integer`, max ~2.1 billion). At
1 snapshot/minute that ceiling is ~4,000 years away. At 1-second sampling it drops
to ~68 years — still safe, but sequence exhaustion is unrecoverable without downtime.
Consider migrating `snapshots.id` to `BIGSERIAL` during this overhaul while the
schema is already changing.

New partitioned child tables created in Phase 1 must define `snapshot_id` as
`BIGINT` from day one (the collector safely inserts current `INT` sequence values
into `BIGINT` columns). When `snapshots.id` is migrated to `BIGSERIAL` in Phase 2, two steps are required:

```sql
-- 1. change the column type (requires full table rewrite + ACCESS EXCLUSIVE lock)
alter table pgfr_record.snapshots alter column id type bigint;
-- snapshots is low-volume (~43,200 rows/month) — rewrite is near-instantaneous

-- 2. change the sequence type and preserve monotonicity
alter sequence snapshots_id_seq as bigint restart with <max_id + 1>;
```

The column type change must precede or accompany the sequence change. Both should
happen in the same maintenance window. Child tables are already `BIGINT` from Phase 1
and require no change.

**Q6: `int4 sample_ts` epoch and overflow horizon.**
The epoch is fixed at `2026-01-01 00:00:00+00`. With `int4` seconds, overflow
occurs around 2094. This is not imminent, but must be documented prominently:
the epoch must never change post-install (corrupts all stored timestamps), and
a migration path must be planned before the limit is approached. See §7.1 for
details.

**Q7: `pg_stat_statements.max` changes mid-retention.**
This GUC requires a restart to change. A reduction (e.g. 5,000 → 1,000) triggers
mass deallocation that resembles resets to the sparse logic. An increase changes
baseline insert volume. Snapshot `pg_stat_statements.max` in the `snapshots` parent
row each tick so readers can detect capacity changes when interpreting deallocation
patterns.

**Q8: Partition count guardrails.**
With TRUNCATE-based retention, empty partition definitions accumulate until the
monthly `drop_ancient_partitions()` slow-path cleans them. At steady state, total
partition count across all tables is approximately `3 × retention_days × table_count`
(active + recently truncated + awaiting drop). At 365-day retention across 10
tables: ~10,950 partitions at peak. This exceeds safe limits without the slow-path.

The monthly DROP of ancient empty partitions is essential — not optional — to keep
the catalog bounded. With it, steady-state count is ~2 × retention_days × table_count.

Practical safety envelope (relcache and syscache pressure; every backend pays
startup cost to load partition metadata; pgbouncer transaction mode amplifies this):

- ≤ 2,000 total: safe
- 2,000–5,000: monitor `pg_stat_database.blk_read_time` and planning time during connection storms
- > 5,000: weekly partitions for archives and aggregates; daily only for hot tables

Emit a warning at install time if `2 × retention_days × partitioned_table_count > 2,000`.
Weekly partitions for low-volume tables is worth evaluating in Phase 3.
