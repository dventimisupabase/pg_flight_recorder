# pg_flight_recorder Reference

[![GitHub release](https://img.shields.io/github/v/release/dventimisupabase/pg_flight_recorder)](https://github.com/dventimisupabase/pg_flight_recorder/releases/latest)
[![Test Suite](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/test.yml/badge.svg)](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/test.yml)
[![Lint](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/lint.yml/badge.svg)](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/lint.yml)

Complete reference for [pg_flight_recorder](README.md) v2. For installation and getting started, see the [README](README.md) and [pgfr_record/README.md](pgfr_record/README.md). For the statistics collected and why, see [STATISTICS.md](STATISTICS.md).

Everything below is a fact about `pgfr_record`, the required core extension. `pgfr_analyze` is covered in one section at the end: it is not yet rebuilt for v2.

## Contents

- [The big picture](#the-big-picture)
- [The manifest](#the-manifest)
  - [The PG15 seed census](#the-pg15-seed-census)
- [Payload dictionary](#payload-dictionary)
- [Archive tables](#archive-tables)
  - [Partitioning and retention](#partitioning-and-retention)
- [Presentation views](#presentation-views)
- [Column classes](#column-classes)
- [Capture plan and the collector](#capture-plan-and-the-collector)
  - [The statement_timeout arming gotcha](#the-statement_timeout-arming-gotcha)
- [Capture ledger](#capture-ledger)
- [Definitional helpers](#definitional-helpers)
  - [`state_as_of(source_view, t)`](#state_as_ofsource_view-t)
  - [`resolve_relation(oid, t)` / `resolve_index(oid, t)`](#resolve_relationoid-t--resolve_indexoid-t)
  - [`deltas(source_view, from_t, to_t)`](#deltassource_view-from_t-to_t)
  - [Generated `COMMENT ON`](#generated-comment-on)
- [Profiles](#profiles)
- [`health_check()`](#health_check)
- [`pgfr_analyze`](#pgfr_analyze)

## The big picture

`pgfr_record` appends debounced, dictionary-encoded jsonb samples of PostgreSQL's own stats views and system views into time-partitioned tables, and drops old partitions. Everything in this reference is machinery driven by one table, `pgfr_record.manifest`: which views, how often, with what identity, kept how long. Every archive table, presentation view, capture-plan entry, and column classification is generated from the manifest plus the live catalog. Re-running `install.sql` regenerates all of it; that is the entire upgrade procedure, including after a PostgreSQL major version upgrade.

## The manifest

`pgfr_record.manifest` is the single design artifact: one row per capture target (a stats view, system view, or catalog projection). Every generator and collector behaves as a pure function of this table.

| Column | Type | Meaning |
|---|---|---|
| `source_view` | `text` (PK) | Schema-qualified source, e.g. `pg_catalog.pg_stat_database`, or a pgfr-defined projection view |
| `min_major` / `max_major` | `int` | PostgreSQL major-version range this target exists on; `max_major IS NULL` means still present |
| `cadence_tier` | `text` | `fast`, `medium`, `slow`, or `on_change`: maps to a pg_cron interval via the active profile |
| `natural_key` | `text[]` | Columns forming this target's identity; `{}` means singleton (no key) |
| `keyless` | `boolean` | True when the source has no stable row identity (e.g. `pg_locks`); forces `debounce = false` |
| `debounce` | `boolean` | Skip appending a row unchanged since its most recent capture, within the current anchor window |
| `compare_ignore` | `text[]` | Columns nulled out of the *compare* payload before hashing (estimator churn, etc.), though the stored payload keeps every value |
| `anchor_every` | `interval` | Cadence of an unconditional full capture for a debounced target; required when `debounce = true` |
| `retention` | `interval` | How long rows are kept, implemented as partition drop, never `DELETE` |
| `logged` | `boolean` | `false` makes the archive table's partitions `UNLOGGED` (default `true`) |
| `size_class` | `text` | Coarse cardinality label (`singleton`, `per_db`, `per_relation`, `per_backend`, or `per_slot`), used only by the cost model and docs |
| `requires` | `text` | Precondition for full visibility: an extension, a GUC, or a role/privilege note |
| `enabled` | `boolean` | `false` rows are still listed, with notes, so "why doesn't pgfr capture X" is queryable. They get no archive table or capture-plan entry |
| `notes` | `text` | Free-text design rationale |

Both `debounce = false OR anchor_every IS NOT NULL` and `keyless = false OR debounce = false` are enforced by `CHECK` constraints, not convention.

### The PG15 seed census

`03_seed_pg15.sql` seeds 41 manifest rows. Counts below are the live table on PostgreSQL 15, queried directly rather than assumed:

| | rows |
|---|---|
| Total manifest rows | 41 |
| Enabled | 35 |
| Disabled (Group E) | 6 |
| Version-gated beyond PG15 (`min_major` 16 or 17) | 2 |
| Active on PG15 (enabled and `min_major <= 15`) | 33 |

**Group A: cumulative counters, singleton / per-db.** Fast tier, 30 days retention, `debounce = false` (cheap, always changing, every sample wanted).

| source_view | key | notes |
|---|---|---|
| `pg_stat_archiver` | `{}` | reset: `stats_reset` |
| `pg_stat_bgwriter` | `{}` | reset: `stats_reset`. PG17 removes checkpoint columns (moved to `pg_stat_checkpointer`); agnostic capture absorbs |
| `pg_stat_wal` | `{}` | reset: `stats_reset` |
| `pg_stat_slru` | `{name}` | per-cache row set, small/bounded cardinality; reset: `stats_reset` |
| `pg_stat_database` | `{datid}` | includes the `datid = 0` shared-objects row; reset: `stats_reset` |
| `pg_stat_database_conflicts` | `{datid}` | nonzero only on standbys |
| `pg_stat_io` (min_major 16) | `{backend_type, object, context}` | the single most valuable addition in the series |
| `pg_stat_checkpointer` (min_major 17) | `{}` | receives the columns split out of `pg_stat_bgwriter` |

**Group B: cumulative counters, per-relation, the cardinality frontier.** Medium tier (statio: slow), `debounce = true`, `anchor_every = 1 day`, 30 days retention.

| source_view | key | compare_ignore | requires | notes |
|---|---|---|---|---|
| `pg_stat_all_tables` | `{relid}` | `{n_live_tup, n_dead_tup, n_mod_since_analyze, n_ins_since_vacuum}` | n/a | the ignore-list keeps estimator churn from defeating debounce; ignored columns are still stored |
| `pg_stat_all_indexes` | `{indexrelid}` | `{}` | n/a | |
| `pg_statio_all_tables` | `{relid}` | `{}` | n/a | slow tier |
| `pg_statio_all_indexes` | `{indexrelid}` | `{}` | n/a | slow tier |
| `pg_statio_all_sequences` | `{relid}` | `{}` | n/a | slow tier |
| `pg_stat_user_functions` | `{funcid}` | `{}` | `track_functions <> none` | |
| `pg_stat_statements` | `{userid, dbid, queryid, toplevel}` | `{}` | `pg_stat_statements` extension | unqualified on purpose, see below |
| `pg_stat_statements_info` | `{}` | `{}` | `pg_stat_statements` extension | fast tier; singleton companion carrying the reset signal that distinguishes a real reset from per-query eviction |

`pg_stat_statements` and `pg_stat_statements_info` are extension-provided views, not `pg_catalog` builtins: `CREATE EXTENSION` installs them wherever the current schema was at the time (`public` on stock PostgreSQL, typically `extensions` on Supabase). The manifest references them unqualified and lets `::regclass` resolve them via `search_path`, exactly as any other client of an extension-provided object would.

**Group C: gauges.** Fast tier, 2 hours retention (this is what the v1 ring buffer becomes when expressed as a retention number), `debounce = false`. 13 rows: `pg_stat_activity` (key `{pid, backend_start}`, where `backend_start` disambiguates pid reuse), `pg_locks` (keyless; join to activity via `pid` at equal `captured_at`), `pg_stat_replication`, `pg_stat_wal_receiver`, `pg_stat_subscription`, `pg_replication_slots` (odometers `restart_lsn`/`confirmed_flush_lsn`; failure to advance is an analyze-side alarm), `pg_prepared_xacts` (usually empty; an aging row is itself an anomaly), and the six default-on progress views (`pg_stat_progress_vacuum`, `_cluster`, `_create_index`, `_basebackup`, `_analyze`, `_copy`).

**Group D: state history.** `on_change` tier, `debounce = true`, `anchor_every = 1 month` (Group D uses monthly partitions per the retention-to-width rule below), 365 days retention.

| source_view | key | notes |
|---|---|---|
| `pg_settings` | `{name}` | flagship: GUC change detection falls out of debounce for free |
| `pg_roles` | `{oid}` | `rolpassword` is stripped from the payload defensively (masked anyway) |
| `pg_hba_file_rules` | `{line_number}` | requires privileged read; degrades via the ledger when unreadable |
| `pg_file_settings` | `{sourcefile, sourceline}` | detects applied-vs-file divergence |
| `pg_extension` | `{oid}` | a catalog table, not a view; captures extension installs/upgrades |
| `pgfr_record.src_catalog_identity` | `{oid}` | the dimension table: resolves any `relid`/`indexrelid` in Group B as of any `captured_at`, surviving OID reuse across DROP/CREATE |

**Group E: disabled, with reasons.** `pg_cursors`, `pg_prepared_statements`, `pg_backend_memory_contexts` (all session-local: they observe pg_cron's own session, not the workload), `pg_timezone_names` (static and enormous), `pg_stats` (per-column planner statistics, a different product, ANALYZE-cadenced), `pg_shmem_allocations` (low routine value; a troubleshooting-profile candidate).

## Payload dictionary

Payloads are stored as **jsonb arrays of values in a fixed positional order**, not objects. An all-numeric stats row spends most of its bytes on repeated key names in an object encoding, and most rows sit below jsonb's TOAST/compression threshold, so that tax is paid in full, twice (heap and WAL). Arrays keep jsonb's heterogeneous container (compact `numeric`, native null, text only where text exists) and drop the repeated-key structure.

The positional order lives once, in `pgfr_record.payload_schemas`:

| Column | Type | Meaning |
|---|---|---|
| `schema_id` | `smallint` (PK, identity) | Referenced by every archive row and by `capture_plan` |
| `source_view` | `text` | Which target this layout belongs to |
| `columns` | `text[]` | Column names in payload array position order: position `i` of a payload is `columns[i+1]` |
| `type_names` | `text[]` | Column type names in the same order; drives presentation-view cast generation |
| `fingerprint` | `text` | Hash of `(source_view, columns, type_names)`; a changed live view shape mints a new row rather than editing this one |
| `first_seen` | `timestamptz` | When this schema_id was minted |

Append-only, like everything else: a changed view shape (a mid-major column addition, most notably `pg_stat_statements`) is a new `payload_schemas` row, never an edit. The **mint-together invariant** closes the one corruption hazard positional encoding introduces: the generated capture statement (`capture_plan.capture_select_sql`) and its `schema_id` are two outputs of one generator run, minted atomically from the same live-column introspection, so the array's column order and the dictionary row describing that order can never drift apart. Because arrays can't distinguish NULL from absent, every position is always present (NULL-filled where needed); this is safe precisely because `schema_id` says exactly which columns exist for that row.

The stored payload is the view's row, *normalized*: keys dictionaried out, exactly as query text already is in `pg_stat_statements`. The "the data model is exactly the PostgreSQL views" promise is made and kept at the presentation layer (below), which is the layer users actually read.

## Archive tables

One table per enabled, version-applicable manifest row, named `pgfr_record.a_<short_name>` (the source view's name without its schema, e.g. `a_pg_stat_database`). Uniform shape everywhere: this is what "schema-agnostic" means.

| Column | Type | Meaning |
|---|---|---|
| `captured_at` | `timestamptz` | When this sample was taken, the tier's single stamp for this run |
| `key` | `jsonb` | Natural-key columns as a jsonb object, e.g. `{"relid": 16384}`; `NULL` when keyless or singleton |
| `key_hash` | `bigint` | `hashtextextended(key::text, 0)`; `NULL` when `key IS NULL`. Drives the debounce anti-join and LOCF reads |
| `row_hash` | `bigint` | `hashtextextended(compare_payload::text, 0)`, with `compare_ignore` columns nulled and `schema_id` folded into the compared text |
| `schema_id` | `smallint` | Which `payload_schemas` row this payload's positions follow (FK) |
| `payload` | `jsonb` | Positional jsonb array of every captured column value |

`PARTITION BY RANGE (captured_at)`, plus one index: `(key_hash, captured_at DESC)`, for the debounce anti-join and LOCF. Nothing indexes `payload`. There is no visibility column here: visibility (`full`, `masked`, or `degraded`) lives in the capture ledger, per run per target, not per archive row.

Plural, uniform-shape tables (rather than one giant generic table) mean retention is per-target partition dropping, a 100k-relation Group B table can't bloat `pg_settings` history, autovacuum sees homogeneous tables, and per-target indexes stay small. The generator makes every one of them from the manifest, so plurality costs no hand-written DDL.

### Partitioning and retention

Partition width is derived from retention by a fixed rule (`_partition_unit()`), not stored in the manifest:

| Retention | Partition width |
|---|---|
| Up to 6 hours | hourly |
| Up to 60 days | daily |
| Longer than 60 days | monthly |

Retention is `ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY` followed by `DROP TABLE` on the detached table, never `DELETE`, anywhere. `maintain_partitions()`, run hourly by its own pg_cron job, is a four-step reconciliation loop rather than a linear script, because `DETACH PARTITION ... CONCURRENTLY` cannot execute from inside a function or procedure body on any supported PostgreSQL version:

1. **Create-ahead.** Pre-create partitions covering at least two widths beyond `now()`, for every target. Ordinary DDL, runs directly.
2. **Schedule detaches.** For each expired, still-attached partition, `cron.schedule()` a one-off pg_cron job (an exact one-time cron spec, not a recurring wildcard) whose command text is *only* the bare `DETACH ... CONCURRENTLY` statement, since pg_cron dispatches it as a single top-level statement and anything else sharing that command string would be wrapped in an implicit transaction, breaking `CONCURRENTLY` again.
3. **Drop retired tables.** Any standalone table (no longer attached to anything) matching a target's naming convention, left over once a prior cycle's detach fired. Ordinary DDL.
4. **Reap.** Unschedule the one-off jobs from step 2 once their target has been fully dropped by step 3.

A partition's full retirement therefore spans up to two maintenance cycles, immaterial given retention windows measured in hours to months and create-ahead already buffering two widths. If a collector's insert would land outside existing partitions (the maintenance job died), the per-target `EXCEPTION` block records the miss in the ledger as `error` rather than raising uncaught; `health_check()` surfaces the underlying staleness.

## Presentation views

`pgfr_record.v_<short_name>` projects an archive table's jsonb-array payloads back into the source view's typed columns, plus `captured_at`. Generated by `generate_presentation_views()`, always `DROP` + `CREATE`, never `CREATE OR REPLACE`: PostgreSQL refuses to replace a view in a way that removes or reorders existing output columns, and a real source view can legitimately do that between majors (PG17 splits checkpoint columns out of `pg_stat_bgwriter`). This is safe because presentation views are freely regenerable; the archive data underneath them is not.

A source view can carry more than one `payload_schemas` row over time (mid-major column accretion, `pg_stat_statements` being the known offender). The view's column set always matches the *current* (highest `schema_id`) shape; rows captured under an earlier, narrower schema get `NULL` for whichever column didn't exist yet, via one `UNION ALL` branch per `schema_id` the source view has ever had. Column positions are resolved per-variant, never assumed to line up across schemas. Presentation views reflect the **current major only**; reading pre-upgrade payloads through post-upgrade views is a best-effort, `pgfr_analyze`-side concern, not guaranteed here.

Array-typed columns (e.g. `pg_settings.enumvals`, a `text[]`) need special handling: the `->>` operator returns a nested array's JSON-bracket text form, not a Postgres array literal, so `_jsonb_element_cast()` reassembles them via `jsonb_array_elements_text()` instead of a plain cast, with an explicit guard for a captured NULL.

Example, from a live PG15 install (`\d+ pgfr_record.v_pg_stat_database`):

```
                                                View "pgfr_record.v_pg_stat_database"
          Column          |           Type           |            Description
--------------------------+--------------------------+------------------------------------
 captured_at              | timestamp with time zone |
 datid                    | oid                      | class: key
 datname                  | name                     | class: label
 numbackends              | integer                  | class: gauge
 xact_commit              | bigint                   | class: counter; reset: stats_reset
 ...
```

## Column classes

`pgfr_record.column_classes(source_view, column_name, class, reset_column)` is the counter/odometer/gauge/label/key legend: definitional, not judgmental, so it lives in `pgfr_record` rather than `pgfr_analyze` (the record layer stores and describes the taxonomy; it never uses it to form an opinion).

- **counter**: monotone and resettable; the derivative is the value proposition. Links to `reset_column` (usually `stats_reset`) when one exists in the same view.
- **odometer**: monotone and non-resettable (LSNs, XIDs); no reset detection needed.
- **gauge**: point-in-time.
- **label**: identity/dimension, not a measurement.
- **key**: a natural-key column.

`generate_column_classes()` derives this **mechanically**, rather than from a hand-typed per-column list. Hand-classifying every column of roughly 40 census views from memory risks exactly the kind of confidently-wrong answer the record/analyze boundary is designed to avoid. The rule order, checked top to bottom:

1. Natural-key membership maps to `key` (identity always wins, even over the override list below: `pid` is a natural-key column on some targets and an override-list gauge on others).
2. A small named override list for numeric-but-not-cumulative columns: `numbackends`, `pid`, `sender_port`, `client_port`, `sync_priority`.
3. A column literally named `stats_reset` maps to `label` (and becomes the `reset_column` for this view's own counters).
4. Type `pg_lsn`, `xid`, or `xid8` maps to `odometer`.
5. A column in this row's `compare_ignore` maps to `gauge` (the same rationale that put it in `compare_ignore`: it's estimate churn, not real change).
6. Column name matching `min_`, `max_`, `mean_`, or `stddev_` maps to `gauge`.
7. Type `timestamptz` or `interval` maps to `gauge`.
8. Remaining numeric types map to `counter`, with `reset_column` linked to `stats_reset` when present.
9. Everything else maps to `label`.

This is a best-effort mechanical classification, not a hand-verified audit against PostgreSQL's own documentation for every column. The override list is a documented starting point, expected to grow as misclassifications surface in practice, the same maintenance posture as `compare_ignore`.

## Capture plan and the collector

`pgfr_record.capture_plan` materializes, per tier, the ordered list of targets the collector iterates: `cadence_tier`, `plan_order`, `source_view`, `archive_table`, `schema_id`, the manifest's identity/debounce facts, and a cached `capture_select_sql` (the SELECT of `key, key_hash, row_hash, payload` from the live source, minted atomically alongside `schema_id` by `generate_capture_plan()`, the other half of the mint-together invariant). It's regenerated wholesale (`TRUNCATE` + repopulate) whenever the manifest changes; unlike the archive tables, this is derived configuration cache, not observed history, so it doesn't fall under the append-only rule.

`pgfr_record.run_tier(p_tier text, p_lock_timeout interval DEFAULT '100ms', p_job_timeout interval DEFAULT NULL)` is the collector core, run once per tier by its own pg_cron job:

- **Single stamp.** One `captured_at` (`t0`) is shared by every target in the tier, so cross-view joins at equal `captured_at` (`pg_locks` joined to `pg_stat_activity`) are exact, not approximate.
- **Debounce / anchor.** A debounced target appends only rows whose `(key_hash, row_hash)` doesn't match its most recent capture within the current anchor window (a `LEFT JOIN LATERAL`, not a bare `NOT IN`, so a value that fluctuates back to an earlier state is correctly re-appended). "Anchor due" is answered statelessly: since anchor cadence equals partition width by manifest construction, it reduces to "does the current partition have any rows yet", with no separate last-anchor tracking table, and self-healing if a prior anchor attempt failed partway.
- **Per-target failure isolation.** Each target's capture is one `INSERT ... SELECT` inside its own `EXCEPTION` block (a subtransaction). A lock-queue hang, permission failure, or error on one target cannot fail the tier or the rest of the run; the ledger row is the handling.
- **Timeouts.** `lock_timeout` is a real, dynamically-enforced per-target bound (`SET LOCAL lock_timeout`, re-affirmed every loop iteration). `job_timeout` is enforced two ways: a cooperative deadline check that stops the tier from *starting* further targets once the budget is spent (works unconditionally, including manual invocation; a target skipped this way simply has no `ledger_captures` row for the run), and, when `run_tier()` is dispatched as the second statement of `SET statement_timeout = ...; SELECT run_tier(...)` (which is how `apply_profile()` schedules every tier job), a genuine caller-side preemptive cancellation of a target that is truly hung, not merely slow. There is no per-target `section_timeout`: it would require dispatching each target as its own top-level statement (via `dblink`/`pg_background`), a dependency this design deliberately does not take on. See "The statement_timeout arming gotcha" below for why.

### The statement_timeout arming gotcha

Confirmed against a live server: `statement_timeout`'s enforcement timer is armed once, at the start of the current top-level statement, using whatever value was in effect at that moment. A `SET`/`SET LOCAL statement_timeout` executed from inside that same top-level statement's own execution, including from inside a called function, does not retroactively re-arm the already-running timer. Since `run_tier()` is invoked as a single top-level call, an internal `SET LOCAL statement_timeout` inside its own body can never preemptively cancel anything about its own execution. `lock_timeout` does not share this defect: a lock wait is checked dynamically against whatever `lock_timeout` is in effect at the moment the wait begins, confirmed separately against a live server, so it remains a real, working, per-target bound with no caveats.

This is why `apply_profile()` schedules each tier's pg_cron job as **two** top-level statements, `SET statement_timeout = '<job_timeout>ms'; SELECT pgfr_record.run_tier(<tier>, <lock_timeout>, <job_timeout>)`, rather than one call to `run_tier()` alone: only a `SET` issued as its own preceding top-level statement genuinely arms preemptive cancellation for the whole call.

`pg_cron` serializes overrunning jobs rather than launching concurrent instances of the same job. This was confirmed against a live instance by scheduling a job on a short interval whose body deliberately overran it, and observing successive invocations start only after the previous one finished, never overlapping. This is the empirical basis for why static, bounded timeouts (`job_timeout(tier) < tier_interval(tier)`, enforced by a `CHECK` constraint on `profile_tiers`) are sufficient on their own, without an adaptive circuit breaker: even under a pathological, sustained overrun, pgfr never accumulates piled-up concurrent collector backends for the same tier.

## Capture ledger

Misses are telemetry, not silence: every target's per-run outcome is recorded, never inferred from absence.

`pgfr_record.ledger_runs (run_id, tier, captured_at, finished_at)` gets exactly one `INSERT` per tier run, appended once after the run's capture-plan loop finishes, never opened and later closed with an `UPDATE`. `run_id` is reserved up front via `nextval` so it's available to `ledger_captures` rows written during the loop, before the `ledger_runs` row itself exists. A crash mid-run leaves no `ledger_runs` row at all, rather than one wedged half-open; `cron.job_run_details` (pg_cron's own log) is the source of truth for whether the top-level call itself errored or overran.

`pgfr_record.ledger_captures (run_id, source_view, outcome, rows_appended, was_anchor, visibility, detail, elapsed, captured_at)` gets one row per `(run, target)`. `outcome` is one of `ok`, `timeout`, `lock_timeout`, `denied`, `error`, or `skipped_disabled`; `visibility` (`full`, `masked`, or `degraded`) reflects the caller's actual privilege at capture time, per run per target, not per row; `detail` carries `SQLERRM` for `outcome = 'error'`.

To find when the recorder was blind:

```sql
SELECT lr.captured_at, lc.source_view, lc.outcome, lc.detail
FROM pgfr_record.ledger_captures lc
JOIN pgfr_record.ledger_runs lr ON lr.run_id = lc.run_id
WHERE lc.outcome <> 'ok'
ORDER BY lr.captured_at DESC;
```

## Definitional helpers

Mechanical, deterministic, threshold-free functions over recorded facts: everything here has exactly one correct answer. This is the record/analyze boundary, tested by the **agent test**: could an AI agent with a dump of `pgfr_record` alone, restored into a separate database, using only psql, make progress on troubleshooting? Everything below is designed to answer yes.

### `state_as_of(source_view, t)`

LOCF (last-observation-carried-forward) reconstruction: for each key, the most recent sample at or before `t`, never searching further back than the start of `t`'s own partition (anchor cadence equals partition width by manifest construction, so that bound is free). Returns `SETOF record`; the caller supplies a column-definition list matching `\d pgfr_record.v_<short_name>`.

Verified example, from a live install:

```sql
SELECT * FROM pgfr_record.state_as_of('pg_catalog.pg_stat_database', now())
    AS t(captured_at timestamptz, datid oid, datname name, numbackends integer,
         xact_commit bigint, xact_rollback bigint, blks_read bigint, blks_hit bigint,
         tup_returned bigint, tup_fetched bigint, tup_inserted bigint, tup_updated bigint,
         tup_deleted bigint, conflicts bigint, temp_files bigint, temp_bytes bigint,
         deadlocks bigint, checksum_failures bigint, checksum_last_failure timestamptz,
         blk_read_time double precision, blk_write_time double precision,
         session_time double precision, active_time double precision,
         idle_in_transaction_time double precision, sessions bigint,
         sessions_abandoned bigint, sessions_fatal bigint, sessions_killed bigint,
         stats_reset timestamptz)
WHERE datname = 'postgres';
```

A point in time before any capture existed returns zero rows, not the earliest available row.

### `resolve_relation(oid, t)` / `resolve_index(oid, t)`

Join through the catalog identity dimension (`pgfr_record.src_catalog_identity`, captured as a Group D target) as of `t`, surviving OID reuse across DROP/CREATE. Mechanically identical to each other, since `pg_class` covers every relkind including indexes; named separately only so a caller resolving an `indexrelid` doesn't have to know that. `t` defaults to `clock_timestamp()`, matching a live lookup when no historical point is given.

```sql
SELECT * FROM pgfr_record.resolve_relation('pgfr_record.manifest'::regclass::oid);
--         captured_at         |  oid  | relname  | relnamespace |   nspname   | relkind | relispartition
-- 2026-08-28 20:08:50.640036+00 | 16468 | manifest |        16467 | pgfr_record | r       | f
```

A nonexistent OID returns zero rows, not an error.

### `deltas(source_view, from_t, to_t)`

Consecutive-sample differences per key over counter/odometer columns, driven by `column_classes`, built directly on `state_as_of()`: join the `to_t` snapshot to the `from_t` snapshot by key, then difference. **Reset-aware**: a decreased counter value, or its linked `reset_column` advancing, yields `NULL` for that interval, never a negative rate. Odometers skip reset detection entirely (that's their definition). A key present at `to_t` but absent at `from_t` is excluded, not fabricated (an inner join on both snapshots). Raises on a keyless source view (there's no identity to correlate two points in time) and on an unknown source view.

Returns `SETOF record`; counter/odometer columns come back as `<column>_delta` (note: `pg_lsn - pg_lsn` yields `numeric`, so an LSN odometer's delta column is `numeric`, not `pg_lsn`); everything else passes through as the `to_t` value under its own name, plus `from_captured_at` and `to_captured_at`.

Verified example, from a live install (two real `pg_stat_wal` captures, about 9 seconds apart):

```sql
SELECT wal_records_delta, wal_bytes_delta, from_captured_at, to_captured_at
FROM pgfr_record.deltas('pg_catalog.pg_stat_wal', :from_t, :to_t)
    AS d(wal_records_delta bigint, wal_fpi_delta bigint, wal_bytes_delta numeric,
         wal_buffers_full_delta bigint, wal_write_delta bigint, wal_sync_delta bigint,
         wal_write_time_delta double precision, wal_sync_time_delta double precision,
         stats_reset timestamptz, from_captured_at timestamptz, to_captured_at timestamptz);
--  wal_records_delta | wal_bytes_delta
--               6366 |         1669927
```

### Generated `COMMENT ON`

`generate_comments()` derives a `COMMENT ON` for every archive table, presentation view, and column from the manifest and `column_classes`: the discovery channel an agent actually uses. `\d+` on any archive table or presentation view explains itself (what it is, its cadence/retention/debounce facts, and per-column class/reset-linkage) without this reference open alongside it. Regenerate whenever the manifest or `column_classes` changes; safe to re-run.

## Profiles

`pgfr_record.profiles(profile_name, lock_timeout, notes)` and `pgfr_record.profile_tiers(profile_name, cadence_tier, tier_interval, job_timeout)` reduce a profile to cadence plus bounds. `job_timeout < tier_interval` is a `CHECK` constraint on `profile_tiers`, not just a convention: a bad profile row cannot be inserted at all.

Shipped profiles:

| Profile | Tier | Interval | job_timeout | lock_timeout |
|---|---|---|---|---|
| `default` | fast | 1 min | 45 s | 100 ms |
| `default` | medium | 5 min | 4 min | 100 ms |
| `default` | slow | 15 min | 12 min | 100 ms |
| `default` | on_change | 5 min | 4 min | 100 ms |
| `troubleshooting` | fast | 20 s | 15 s | 100 ms |
| `troubleshooting` | medium | 1 min | 45 s | 100 ms |
| `troubleshooting` | slow | 15 min | 12 min | 100 ms |
| `troubleshooting` | on_change | 5 min | 4 min | 100 ms |

`pgfr_record.apply_profile(profile_name)` reschedules the four tier jobs to the named profile's cadence and bounds, dispatching each as the two-statement `SET statement_timeout; SELECT run_tier(...)` command described above. It never touches the manifest, and there is no separate "currently active profile" marker: `cron.job`'s live schedule/command is the source of truth for what's applied. `pg_cron` accepts a literal `"N seconds"` schedule syntax for sub-minute jobs (used by `troubleshooting`'s tighter fast cadence), confirmed working against a live instance.

`pgfr_record.enable()` applies the `default` profile and schedules the hourly `maintain_partitions()` job: the single "turn pgfr_record on" operation. `pgfr_record.disable()` unschedules the four tier jobs and the maintenance job; archive data, the manifest, and the capture plan are untouched. Both are idempotent. Note: `cron.schedule()` on an already-scheduled job updates its schedule/command but does **not** reactivate a previously deactivated job on its own (confirmed against a live instance); `apply_profile()` and `enable()` both explicitly set `active = true` after scheduling, for exactly this reason.

## `health_check()`

`pgfr_record.health_check()` returns `(check_name, status, detail)` rows covering:

- **`cron_job: <tier>` / `cron_job: maintenance`**: is the job scheduled and active.
- **`last_capture: <tier>`**: when the tier last finished, judged against that tier's own live schedule (read back from `cron.job`, not a hardcoded assumption) rather than a fixed threshold.
- **`ledger_miss_rate_1h`**: the fraction of captures in the last hour that didn't come back `ok`.
- **`partitions: <table>`**: does every pgfr-owned partitioned table have at least two widths of partitions ahead of now, and zero expired-but-still-attached partitions.

Every check is read-only and threshold-free in the judgmental sense: each is a fixed structural fact (is a job scheduled, is a partition still attached past retention), never an opinion about what's normal. Opinions are `pgfr_analyze`'s job.

**`health_check()` is verified genuinely read-only, two ways.** This matters because of a real v1 incident: v1's `health_check()` internally called `cleanup()`, which could itself fail or time out, defeating the entire point of a status check. v2's `health_check()` is confirmed, empirically, to complete successfully inside a hard `READ ONLY` transaction, and that empirical check is load-bearing, because declaring a function `STABLE` does **not**, on its own, prevent it from calling a mutating function: PostgreSQL only checks a function's own literal body against its declared volatility, not what it calls transitively. A `READ ONLY` transaction, by contrast, is enforced through any depth of function calls (confirmed separately: forcing `maintain_partitions()` to do real work inside a `READ ONLY` transaction fails with "cannot execute CREATE TABLE in a read-only transaction", the exact failure mode this guard would catch were it ever reintroduced).

## `pgfr_analyze`

`pgfr_analyze` is not yet rebuilt for v2. The schema exists as a placeholder (`CREATE SCHEMA pgfr_analyze` with a `COMMENT ON SCHEMA` explaining the deferral) so the two-extension install pipeline keeps working while it's built out; it currently has no tables, views, or functions. See `pgfr-v2-context-pack.md`'s Appendix (milestone 7) for what it's designed to eventually own: anomaly/regression/storm detection, trends, capacity views, and `report()`, all consuming `pgfr_record`'s definitional helpers and column classes, owning none of them. A `pgfr_record`-only install (or a `pg_dump` of one) is fully self-contained and self-describing in the meantime; `pgfr_analyze`, once it exists, will make conclusions faster, not make them possible.
