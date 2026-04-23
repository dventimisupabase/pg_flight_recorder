# Ring Buffer Bloat Benchmark

**Date:** 2026-03-04  
**Environment:** Hetzner ccx23 (4 dedicated cores, 16 GiB RAM), Ubuntu 24.04, Postgres 18.3 (PGDG)  
**Branch:** `storage-overhaul-spec`  
**Workload:** pgbench scale 10, 16 clients, 300 s — ~1.8 M transactions, ~6,030 TPS  
**Sampler:** `sample()` + `sample_ring()` called every 5 s during full load (60 samples total)  

---

## Results

### Table sizes after 300 s of sustained load

| Table                                       | Before load   | After load    | Dead tuples |
|---------------------------------------------|---------------|---------------|-------------|
| **Old ring (UPDATE-based)**                 |               |               |             |
| `samples_ring`                              | 64 KiB        | 64 KiB        | 1           |
| `wait_samples_ring`                         | 896 KiB       | 912 KiB       | 145         |
| `activity_samples_ring`                     | 280 KiB       | 320 KiB       | 171         |
| `lock_samples_ring`                         | 976 KiB       | 1,008 KiB     | 226         |
| **Old ring total**                          | **2,216 KiB** | **2,304 KiB** | **543**     |
|                                             |               |               |             |
| **New ring v2 (INSERT+TRUNCATE)**           |               |               |             |
| `wait_samples_0` (current slot)             | 0             | 64 KiB        | 0           |
| `wait_samples_1/2` (older slots)            | 0             | 16 KiB each   | 0           |
| `lock_samples_0/1/2`                        | 0             | 8 KiB each    | 0           |
| **New ring total (excl. activity_samples)** | **0**         | **~120 KiB**  | **0**       |

**Bloat reduction: ~95% smaller hot footprint, zero dead tuples.**

`activity_samples` not present in this run — the VM used `david-patched.sql`
which predates section 11. Expected size: ~30-50 KiB for top-25 sessions over
300 s at 5 s cadence (60 ticks × 16 active clients × ~50 bytes/row).

### Storage efficiency (v2 wait_samples)

| Metric                                 | Value     |
|----------------------------------------|-----------|
| Rows inserted (60 ticks × ~1 database) | 64        |
| Data size (pg_column_size)             | 11 KiB    |
| Bytes per row (data only)              | 175 bytes |
| Dead tuples                            | 0         |

175 bytes/row for integer[]-encoded wait samples vs ~2 KiB/slot in the old
pre-populated wait_samples_ring. The encoding compresses 14 distinct wait events
across 16 clients into a single row per database per tick.

### Wait event map after 300 s load (14 entries)

| id | state               | type   | event         |
|----|---------------------|--------|---------------|
| 1  | active              | Lock   | transactionid |
| 2  | active              | LWLock | WALWrite      |
| 3  | active              | IO     | WalSync       |
| 4  | idle in transaction | Client | ClientRead    |
| 5  | active              | Lock   | tuple         |
| 6  | active              | Client | ClientRead    |
| 7  | active              | CPU*   | CPU*          |
| 8  | idle in transaction | IdleTx | IdleTx        |
| 9  | active              | LWLock | LockManager   |
| 10 | idle in transaction | Lock   | transactionid |
| 11 | idle in transaction | LWLock | LockManager   |
| 12 | idle in transaction | LWLock | WALWrite      |
| 13 | active              | IO     | WalWrite      |
| 14 | active              | LWLock | BufferContent |

Dictionary bounded: 14 entries after 300 s of 6,030 TPS load. In production
this converges quickly and then stops growing (wait event space is finite).

### Rotation correctness

`rotate_ring()` correctly advanced slot 0 → 1 and truncated slot 2 (oldest).
Post-rotation: slot 2 tables read 0 bytes — TRUNCATE reclaimed space immediately,
no autovacuum needed, no dead tuple accumulation.

---

## Key findings

1. **Zero dead tuples** — INSERT+TRUNCATE model eliminates UPDATE bloat entirely.
   Old ring accumulated 543 dead tuples in 300 s at 5 s sample cadence.

2. **~95% smaller hot footprint** — 120 KiB vs 2,304 KiB after equivalent load.
   The old ring pre-allocates all slots upfront (12,000 rows for wait_samples_ring);
   the new ring only materializes rows that have data.

3. **Instant space reclaim on rotation** — TRUNCATE is O(1) and needs no follow-up
   vacuum. Old ring required autovacuum to reclaim dead tuple space.

4. **Sparse by design** — 64 wait_sample rows for 60 ticks (1 row per database per
   tick, not 100 rows pre-populated per slot). At 1 s cadence over 30 days with
   5,000 distinct queries the projected size is well within the spec §5.2 estimate.

5. **175 bytes/row measured** — integer[] encoding is compact. The SPEC assumed
   ~280 bytes for statement_snapshots; wait_samples at 175 bytes/row is better
   than estimated.

---

## Caveats

- `activity_samples` not benchmarked on this run (absent from the VM install).
  Will be included in a follow-up run once merged to main.
- Lock samples: pgbench TPC-B generates transactionid + tuple locks;
  lock_samples_N were populated but exact row counts not captured.
- 300 s is a short window; production bloat in the old model compounds over
  hours. The 543 dead tuples in 5 min would be ~157,000/day at that rate without
  autovacuum.
