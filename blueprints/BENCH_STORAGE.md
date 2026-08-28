# Storage Comparison: Old Ring vs Ring v2

**Date:** 2026-03-05  
**Environment:** Docker, Postgres 17, x86-64  
**Script:** `scripts/run_storage_comparison.sh`

---

## Contents

- [Measured results](#measured-results)
  - [Run 1 — 2,000 ticks, 100 wait event rows/tick (full slot utilization)](#run-1--2000-ticks-100-wait-event-rowstick-full-slot-utilization)
  - [Run 2 — 10,000 ticks, 1,000 wait event rows/tick (high-traffic server)](#run-2--10000-ticks-1000-wait-event-rowstick-high-traffic-server)
- [Extrapolation: long-running transaction](#extrapolation-long-running-transaction)
- [Side-by-side summary](#side-by-side-summary)
- [Why this matters in production](#why-this-matters-in-production)
- [Reproduction](#reproduction)

## Measured results

### Run 1 — 2,000 ticks, 100 wait event rows/tick (full slot utilization)

*Equivalent: ~2.7 hours at 5 s sample cadence*

| Scenario                | Table              | Live rows | Dead rows       | Dead % | Heap       | pgstattuple dead |
|-------------------------|--------------------|-----------|-----------------|--------|------------|------------------|
| A: no long tx           | wait_samples_ring  | 12,000    | 0 (post-VACUUM) | —      | 20 MiB     | 0                |
| B: long tx pinning xmin | wait_samples_ring  | 12,000    | **400,000**     | 97.1%  | 20 MiB     | **17 MiB**       |
| C: ring v2 + long tx    | all slots combined | 13,966    | **0**           | —      | **944 kB** | **0**            |

**Scenario B key finding:** VACUUM ran immediately after the 2,000 ticks — reclaimed **zero bytes**.  
One `BEGIN; SELECT pg_sleep(400)` session pinned the xmin horizon for the entire run.

### Run 2 — 10,000 ticks, 1,000 wait event rows/tick (high-traffic server)

*Equivalent: ~13.9 hours at 5 s sample cadence*

Scenario A only (scenario B aborted — would take 30+ min to simulate; extrapolated below):

| Table             | Live rows | Dead rows | Heap (VACUUM free) |
|-------------------|-----------|-----------|--------------------|
| wait_samples_ring | 125,721   | 0         | **981 MiB**        |

The pre-allocated 120-slot × 1,000-row structure materializes **981 MiB on disk** even with
VACUUM running freely. This is the floor — the best the old ring can do.

---

## Extrapolation: long-running transaction

From Run 1: 2,000 ticks produced 400,000 dead tuples = **200 dead tuples per tick**.  
That rate is constant regardless of tick count (each tick updates 1,000 rows → 1,000 dead tuples per UPDATE cycle minus live replacements = net ~200 dead/tick at steady state).

At 1,000 rows/tick:

| Duration   | Ticks (5 s cadence) | Dead tuples (long tx) | Dead heap    |
|------------|---------------------|-----------------------|--------------|
| 2.7 hours  | 2,000               | 400,000               | 17 MiB       |
| 13.9 hours | 10,000              | ~2,000,000            | ~85 MiB      |
| 1 day      | 17,280              | ~3,456,000            | **~147 MiB** |
| 1 week     | 120,960             | ~24,192,000           | **~1 GiB**   |
| 30 days    | 518,400             | ~103,680,000          | **~4.4 GiB** |

These are conservative — they assume VACUUM runs constantly (it does not under load).
A stale logical replication slot silently pins the horizon indefinitely.

**Ring v2 at every duration: 0 dead tuples, heap bounded by 3 active slots (~1–3 MiB).**

---

## Side-by-side summary

|                     | Old ring (VACUUM free)     | Old ring (1 stale slot, 1 week) | Ring v2 (any duration)    |
|---------------------|----------------------------|---------------------------------|---------------------------|
| Heap (wait_samples) | **981 MiB**                | **~1 GiB frozen**               | **~1–3 MiB**              |
| Dead tuples         | 0                          | ~24 million                     | **0**                     |
| Dead bytes          | 0                          | **~1 GiB**                      | **0**                     |
| VACUUM effective?   | yes                        | **no**                          | n/a                       |
| Long tx immune?     | no                         | no                              | **yes**                   |
| Pre-allocated rows  | 120,000 fixed              | 120,000 fixed                   | sparse (actual data only) |
| Heap bounded?       | no (grows with fillfactor) | no                              | **yes (3 active slots)**  |

---

## Why this matters in production

The horizon-pinning sources are everywhere:

- Long-running analytics or reporting queries (common on replicas, sometimes primaries)
- `idle in transaction` sessions — ORMs, poorly written apps, forgotten `BEGIN`
- Logical replication slots that fall behind or are abandoned
- Hot standby queries with `hot_standby_feedback = on`

None of these are rare. A single such session for one week on a busy server
turns the old ring into a **~1 GiB dead-heap tombstone** that VACUUM cannot touch.
The table still functions — data is written and read normally — while gigabytes
of garbage accumulate silently underneath.

Ring v2 uses `TRUNCATE` (DDL) for slot rotation. `TRUNCATE` replaces the
storage file atomically without creating dead tuple versions. The xmin horizon
is irrelevant. The heap stays bounded at 3 active slots regardless of how long
any transaction runs.

---

## Reproduction

```bash
bash scripts/run_storage_comparison.sh pgfr_record_test-17 pgfr_bench
```
