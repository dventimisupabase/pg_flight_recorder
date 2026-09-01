# pg_flight_recorder Reference

[![GitHub release](https://img.shields.io/github/v/release/dventimisupabase/pg_flight_recorder)](https://github.com/dventimisupabase/pg_flight_recorder/releases/latest)
[![Test Suite](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/test.yml/badge.svg)](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/test.yml)
[![Lint](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/lint.yml/badge.svg)](https://github.com/dventimisupabase/pg_flight_recorder/actions/workflows/lint.yml)

Complete reference for [pg_flight_recorder](README.md) v2. For installation and getting started, see the [README](README.md) and [pgfr_record/README.md](pgfr_record/README.md). For the statistics collected and why, see [STATISTICS.md](STATISTICS.md).

Everything through [Profiles](#profiles) and [`health_check()`](#health_check) is a fact about `pgfr_record`, the required core extension. The [`pgfr_analyze`](#pgfr_analyze) section at the end covers the optional analysis extension: reporting, anomaly detection, and capacity views built on top of `pgfr_record`'s captured data.

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
- [Rollups](#rollups)
- [Capture ledger](#capture-ledger)
- [Definitional helpers](#definitional-helpers)
  - [`state_as_of(source_view, t)`](#state_as_ofsource_view-t)
  - [`latest_state(source_view, t)`](#latest_statesource_view-t)
  - [`resolve_relation(oid, t)` / `resolve_index(oid, t)`](#resolve_relationoid-t--resolve_indexoid-t)
  - [`deltas(source_view, from_t, to_t)`](#deltassource_view-from_t-to_t)
  - [`rollup_deltas(source_view, from_bucket, to_bucket)`](#rollup_deltassource_view-from_bucket-to_bucket)
  - [Generated `COMMENT ON`](#generated-comment-on)
- [Profiles](#profiles)
- [`health_check()`](#health_check)
- [`pgfr_analyze`](#pgfr_analyze)
  - [Configuration](#configuration)
  - [Coverage and gaps](#coverage-and-gaps)
  - [Configuration tracking](#configuration-tracking)
  - [Query dictionary and query-level analysis](#query-dictionary-and-query-level-analysis)
  - [xmin horizon](#xmin-horizon)
  - [Anomaly detection](#anomaly-detection)
  - [Capacity summary](#capacity-summary)
  - [Self overhead](#self-overhead)
  - [Preflight check](#preflight-check)
  - [Check alerts](#check-alerts)
  - [Quarterly review](#quarterly-review)
  - [Table hotspots](#table-hotspots)
  - [Index analysis](#index-analysis)
  - [Activity readers](#activity-readers)
  - [Composing reports](#composing-reports)

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
| `rollup_retention` | `interval` | How long compressed rollup rows are kept, independent of `retention`; `NULL` means this target has no rollup. See [Rollups](#rollups) |
| `rollup_granularity` | `interval` | Rollup bucket width, e.g. 1 day. Required when `rollup_retention` is set, and must be strictly less than `retention` |
| `logged` | `boolean` | `false` makes the archive table's partitions `UNLOGGED` (default `true`) |
| `size_class` | `text` | Coarse cardinality label (`singleton`, `per_db`, `per_relation`, `per_backend`, or `per_slot`), used only by the cost model and docs |
| `requires` | `text` | Precondition for full visibility: an extension, a GUC, or a role/privilege note |
| `enabled` | `boolean` | `false` rows are still listed, with notes, so "why doesn't pgfr capture X" is queryable. They get no archive table or capture-plan entry |
| `notes` | `text` | Free-text design rationale |

Both `debounce = false OR anchor_every IS NOT NULL` and `keyless = false OR debounce = false` are enforced by `CHECK` constraints, not convention. So is `rollup_retention IS NULL OR (rollup_granularity IS NOT NULL AND rollup_granularity < retention)`.

### The PG15 seed census

`03_seed_pg15.sql` plus later, additive rows (`pg_catalog.pg_database`, `pg_catalog.pg_ident_file_mappings`, and `pg_catalog.pg_publication_tables` in Group D; `pg_catalog.pg_stat_replication_slots` and `pg_catalog.pg_stat_subscription_stats` in Group A; `pg_catalog.pg_sequences` in Group B; `pg_catalog.pg_stat_ssl` and `pg_catalog.pg_stat_gssapi` in Group C) seed 49 manifest rows. Counts below are the live table on PostgreSQL 15, queried directly rather than assumed:

| | rows |
|---|---|
| Total manifest rows | 49 |
| Enabled | 43 |
| Disabled (Group E) | 6 |
| Version-gated beyond PG15 (`min_major` 16 or 17) | 2 |
| Active on PG15 (enabled and `min_major <= 15`) | 41 |

**Group A: cumulative counters, singleton / per-db.** Fast tier, 365 days retention, `debounce = false` (cheap, always changing, every sample wanted). Bounded, singleton/per-db cardinality keeps a year's depth cheap even at raw resolution, so Group A has no rollup: unlike Group B, there is no compression problem here to solve.

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
| `pg_stat_replication_slots` | `{slot_name}` | logical-decoding spill/stream byte and txn counters; reset: `stats_reset`. Distinct from `pg_replication_slots` (Group C), which carries LSN/config columns, not counters |
| `pg_stat_subscription_stats` | `{subid}` | apply/sync error counts; reset: `stats_reset`. Distinct from `pg_stat_subscription` (Group C), which carries worker pid/lag columns, not counters |

**Group B: cumulative counters, per-relation, the cardinality frontier.** Medium tier (statio: slow), `debounce = true`, `anchor_every = 1 day`, 30 days retention. All nine targets below also roll up to 365 days at 1-day buckets; see [Rollups](#rollups).

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
| `pg_sequences` | `{schemaname, sequencename}` | `{}` | n/a | `last_value` against `max_value` is sequence-exhaustion risk, the same category of problem as XID/MultiXID wraparound distance. No `oid` column on this view, so identity here is name-based and does not survive a DROP/CREATE or rename the way every other `relid`/`indexrelid`-keyed Group B target does via `src_catalog_identity` |

`pg_stat_statements` and `pg_stat_statements_info` are extension-provided views, not `pg_catalog` builtins: `CREATE EXTENSION` installs them wherever the current schema was at the time (`public` on stock PostgreSQL, typically `extensions` on Supabase). The manifest references them unqualified and lets `::regclass` resolve them via `search_path`, exactly as any other client of an extension-provided object would.

**Group C: gauges.** Fast tier, 2 hours retention, `debounce = false`. All fifteen targets below also roll up to 365 days at 1-hour buckets; see [Rollups](#rollups).

| source_view | key | notes |
|---|---|---|
| `pg_stat_activity` | `{pid, backend_start}` | `backend_start` disambiguates pid reuse; dict: `query` (analyze-side) |
| `pg_locks` | keyless | no stable identity; join to activity via `pid` at equal `captured_at` (exact, by the single-stamp rule) |
| `pg_stat_replication` | `{pid}` | odometers: `sent_lsn`, `write_lsn`, `flush_lsn`, `replay_lsn` |
| `pg_stat_wal_receiver` | `{}` | standby-side; odometers on received LSNs |
| `pg_stat_subscription` | `{subid}` | |
| `pg_replication_slots` | `{slot_name}` | odometers: `restart_lsn`, `confirmed_flush_lsn`; failure to advance is an analyze-side alarm |
| `pg_prepared_xacts` | `{gid}` | usually empty; an aging row is itself an anomaly |
| `pg_stat_progress_vacuum` | `{pid}` | default-on: empty view costs one `SELECT` |
| `pg_stat_progress_cluster` | `{pid}` | default-on |
| `pg_stat_progress_create_index` | `{pid}` | default-on |
| `pg_stat_progress_basebackup` | `{pid}` | default-on |
| `pg_stat_progress_analyze` | `{pid}` | default-on |
| `pg_stat_progress_copy` | `{pid}` | default-on |
| `pg_stat_ssl` | `{pid}` | one row per connection, regular and replication alike |
| `pg_stat_gssapi` | `{pid}` | one row per connection, regular and replication alike |

**Group D: state history.** `on_change` tier, `debounce = true`, `anchor_every = 1 month` (Group D uses monthly partitions per the retention-to-width rule below), 365 days retention.

| source_view | key | notes |
|---|---|---|
| `pg_settings` | `{name}` | flagship: GUC change detection falls out of debounce for free |
| `pg_roles` | `{oid}` | `rolpassword` is stripped from the payload defensively (masked anyway) |
| `pg_hba_file_rules` | `{line_number}` | requires privileged read; degrades via the ledger when unreadable |
| `pg_file_settings` | `{sourcefile, sourceline}` | detects applied-vs-file divergence |
| `pg_extension` | `{oid}` | a catalog table, not a view; captures extension installs/upgrades |
| `pgfr_record.src_catalog_identity` | `{oid}` | the dimension table: resolves any `relid`/`indexrelid` in Group B as of any `captured_at`, surviving OID reuse across DROP/CREATE. Also carries `relfrozenxid`/`relminmxid`/`reltuples` for per-relation XID/MultiXID wraparound distance |
| `pg_database` | `{oid}` | a catalog table, not a view; `datfrozenxid`/`datminmxid` give the database-level half of wraparound distance tracking |
| `pg_ident_file_mappings` | `{line_number}` | the `pg_ident.conf` companion to `pg_hba_file_rules`, same privileged-read/ledger-degradation story. PG16+ adds `map_number`/`file_name` columns absent on PG15, handled automatically by the payload dictionary's per-major schema variants |
| `pg_publication_tables` | `{pubname, schemaname, tablename}` | which tables are actually published; the publisher-side counterpart to `pg_stat_subscription` (Group C) and `pg_stat_subscription_stats` (Group A), which only cover the subscriber side |

**Group E: disabled, with reasons.** Disabled rows never get an archive table or capture-plan entry; they exist so "why doesn't pgfr capture X" is queryable.

| source_view | reason |
|---|---|
| `pg_cursors` | session-local: observes pg_cron's own session, not the workload |
| `pg_prepared_statements` | session-local |
| `pg_backend_memory_contexts` | session-local (PG15 form); a troubleshooting-profile candidate in later PG majors |
| `pg_timezone_names` | static and enormous |
| `pg_stats` | per-column planner statistics: huge, ANALYZE-cadenced, a different product |
| `pg_shmem_allocations` | low routine value; a troubleshooting-profile candidate |

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

`PARTITION BY RANGE (captured_at)`, plus one index: `(key_hash, captured_at DESC)`, for the debounce anti-join and LOCF. Nothing indexes `payload`. Visibility (`full`, `masked`, or `degraded`) lives in the capture ledger, per run per target, rather than on the archive row itself.

Plural, uniform-shape tables (rather than one giant generic table) mean retention is per-target partition dropping, a 100k-relation Group B table can't bloat `pg_settings` history, autovacuum sees homogeneous tables, and per-target indexes stay small. The generator makes every one of them from the manifest, so plurality costs no hand-written DDL.

### Partitioning and retention

Partition width is derived from retention by a fixed rule (`_partition_unit()`), not stored in the manifest:

| Retention | Partition width |
|---|---|
| Up to 6 hours | hourly |
| Up to 60 days | daily |
| Longer than 60 days | monthly |

Retention is `ALTER TABLE ... DETACH PARTITION` followed by `DROP TABLE` on the detached table, never `DELETE`, anywhere. `maintain_partitions()`, run hourly by its own pg_cron job, is a four-step reconciliation loop rather than a linear script, because `DETACH PARTITION ... CONCURRENTLY` cannot execute from inside a function or procedure body on any supported PostgreSQL version (`DETACH PARTITION ... FINALIZE` has no such restriction and does run directly inside the function):

1. **Create-ahead.** Pre-create partitions covering at least two widths beyond `now()`, for every target. Ordinary DDL, runs directly.
2. **Detach expired, still-attached partitions.** A partition already marked `pg_inherits.inhdetachpending` (a prior `CONCURRENTLY` detach left mid-flight, e.g. by a connection pooler recycling the session between its two internal transactions, confirmed happening in practice on managed Postgres) is finalized directly, right here, ordinary DDL. Everything else gets a fresh `cron.schedule()` one-off pg_cron job (an exact one-time cron spec, not a recurring wildcard) whose command text is *only* the bare `DETACH ... CONCURRENTLY` statement, since pg_cron dispatches it as a single top-level statement and anything else sharing that command string would be wrapped in an implicit transaction, breaking `CONCURRENTLY` again. `cron.schedule()` upserts unconditionally, with no "already scheduled" guard: a prior one-off attempt that already fired and failed for any transient reason is spent and would never retry on its own otherwise, so every still-expired-and-attached partition gets a fresh attempt every hourly cycle until one succeeds.
3. **Drop retired tables.** Any standalone table (no longer attached to anything) matching a target's naming convention, left over once a detach completed (via step 2's `FINALIZE` in this same cycle, or a prior cycle's dispatched `CONCURRENTLY` job). Ordinary DDL.
4. **Reap.** Unschedule the one-off jobs from step 2 once their target has been fully dropped by step 3.

A partition's full retirement therefore spans up to two maintenance cycles in the common case (a `FINALIZE` recovery can resolve in one), immaterial given retention windows measured in hours to months and create-ahead already buffering two widths. If a collector's insert would land outside existing partitions (the maintenance job died), the per-target `EXCEPTION` block records the miss in the ledger as `error` rather than raising uncaught; `health_check()` surfaces the underlying staleness.

## Presentation views

`pgfr_record.v_<short_name>` projects an archive table's jsonb-array payloads back into the source view's typed columns, plus `captured_at`. Generated by `generate_presentation_views()`, always `DROP` + `CREATE`, never `CREATE OR REPLACE`: PostgreSQL refuses to replace a view in a way that removes or reorders existing output columns, and a real source view can legitimately do that between majors (PG17 splits checkpoint columns out of `pg_stat_bgwriter`). This is safe because presentation views are freely regenerable; the archive data underneath them is not.

A source view can carry more than one `payload_schemas` row over time (mid-major column accretion, `pg_stat_statements` being the known offender). The view's column set always matches the *current* (highest `schema_id`) shape; rows captured under an earlier, narrower schema get `NULL` for whichever column didn't exist yet, via one `UNION ALL` branch per `schema_id` the source view has ever had. Column positions are resolved per-variant, never assumed to line up across schemas. Presentation views reflect the **current major only**; reading pre-upgrade payloads through post-upgrade views is a best-effort, `pgfr_analyze`-side concern, not guaranteed here.

Array-typed columns (e.g. `pg_settings.enumvals`, a `text[]`) need special handling: the `->>` operator returns a nested array's JSON-bracket text form, not a Postgres array literal, so `_jsonb_element_cast()` reassembles them via `jsonb_array_elements_text()` instead of a plain cast, with an explicit guard for a captured NULL.

Example (`\d+ pgfr_record.v_pg_stat_database`):

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
2. A small named override list for numeric-but-not-cumulative columns: `numbackends`, `pid`, `sender_port`, `client_port`, `sync_priority`, `reltuples`, `bits`, `client_serial`, `start_value`, `increment_by`, `cache_size`, `map_number`, `leader_pid`, `query_id`. `pg_sequences.last_value` is deliberately not on this list: it behaves like a real counter (reset-aware protection from `deltas()` covers a `RESTART` or a `CYCLE` wraparound without needing a `reset_column`), and is exactly the consumption-rate signal that target exists to capture.
3. A second, name-based override for point-in-time condition text columns: `wait_event`, `wait_event_type`, `state` map to `gauge`. These are the sampled quantity Mode A's time-in-state estimation (see `STATISTICS.md`) is actually built on, not inert identity text like `usename`/`datname`; the type-driven default further down can't tell the two apart on its own.
4. A column literally named `stats_reset` maps to `label` (and becomes the `reset_column` for this view's own counters).
5. Type `pg_lsn`, `xid`, or `xid8` maps to `odometer`.
6. A column in this row's `compare_ignore` maps to `gauge` (the same rationale that put it in `compare_ignore`: it's estimate churn, not real change).
7. Column name matching `min_`, `max_`, `mean_`, or `stddev_` maps to `gauge`.
8. Type `timestamptz` or `interval` maps to `gauge`.
9. Remaining numeric types map to `counter`, with `reset_column` linked to `stats_reset` when present.
10. Everything else maps to `label`.

This is a best-effort mechanical classification, not a hand-verified audit against PostgreSQL's own documentation for every column. The override list is a documented starting point, expected to grow as misclassifications surface in practice, the same maintenance posture as `compare_ignore`.

## Capture plan and the collector

`pgfr_record.capture_plan` materializes, per tier, the ordered list of targets the collector iterates: `cadence_tier`, `plan_order`, `source_view`, `archive_table`, `schema_id`, the manifest's identity/debounce facts, and a cached `capture_select_sql` (the SELECT of `key, key_hash, row_hash, payload` from the live source, minted atomically alongside `schema_id` by `generate_capture_plan()`, the other half of the mint-together invariant). It's regenerated wholesale (`TRUNCATE` + repopulate) whenever the manifest changes; unlike the archive tables, this is derived configuration cache, not observed history, so it doesn't fall under the append-only rule.

`pgfr_record.run_tier(p_tier text, p_lock_timeout interval DEFAULT '100ms', p_job_timeout interval DEFAULT NULL)` is the collector core, run once per tier by its own pg_cron job:

- **Single stamp.** One `captured_at` (`t0`) is shared by every target in the tier, so cross-view joins at equal `captured_at` (`pg_locks` joined to `pg_stat_activity`) are exact, not approximate.
- **Debounce / anchor.** A debounced target appends only rows whose `(key_hash, row_hash)` doesn't match its most recent capture within the current anchor window (a `LEFT JOIN LATERAL`, not a bare `NOT IN`, so a value that fluctuates back to an earlier state is correctly re-appended). "Anchor due" is answered statelessly: since anchor cadence equals partition width by manifest construction, it reduces to "does the current partition have any rows yet", with no separate last-anchor tracking table, and self-healing if a prior anchor attempt failed partway.
- **Per-target failure isolation.** Each target's capture is one `INSERT ... SELECT` inside its own `EXCEPTION` block (a subtransaction). A lock-queue hang, permission failure, or error on one target cannot fail the tier or the rest of the run; the ledger row is the handling.
- **Timeouts.** `lock_timeout` bounds each target's lock wait: it's checked dynamically at the moment a wait begins (`SET LOCAL lock_timeout`, re-affirmed every loop iteration), so it applies in full to every target in turn. `job_timeout` bounds the tier as a whole, two ways: a cooperative deadline check before starting each target, which stops the loop from starting anything further once the tier's elapsed time exceeds the budget (a target skipped this way simply has no `ledger_captures` row for the run), and a caller-side `SET statement_timeout`, issued by `apply_profile()` as its own statement immediately before calling `run_tier()` (`SET statement_timeout = ...; SELECT run_tier(...)`), which can cancel a target that is genuinely hung partway through its own capture.

`pg_cron` never runs two instances of the same tier job concurrently: an overrunning job simply delays that tier's next tick rather than stacking a second instance on top of it. Together with `job_timeout(tier) < tier_interval(tier)` (enforced by a `CHECK` constraint on `profile_tiers`), a tier never accumulates more than one running collector backend at a time.

## Rollups

Group B's 30-day retention and Group C's 2-hour retention are both far shorter than Group D's 365-day config-change history, which limits how far back a config change (`pgfr_analyze.config_changes()`) can be correlated against the counter/gauge behavior around it. Rollups close that gap: a compressed, long-horizon history alongside each target's raw archive, at a fraction of the storage a full year at raw resolution would cost.

`pgfr_record.manifest.rollup_retention` and `rollup_granularity` (bucket width) govern it, per target: `NULL` on both means no rollup; when set, `rollup_granularity` must be strictly narrower than `retention` (a `CHECK` constraint, not convention), since a bucket can only close by aggregating raw rows still guaranteed to exist.

A rollup takes one of two shapes, chosen automatically from what the target's own `column_classes`/`rollup_specs` rows say:

- **Endpoint** (Group B, counters/odometers): one row per `(bucket, key)`, storing the first and last observed value of every counter/odometer column in that bucket, the two points a reset-aware delta needs. Column order follows `payload_schemas`' own order. No primary key, matching the archive tables' own convention: uniqueness is the collector's bucket-close discipline (below), not a database constraint.
- **Stat** (Group C, gauges): one row per `(bucket, stat_name)`, aggregated across every key in the bucket, since Group C's value is "did this happen in this bucket", not a per-backend/per-slot history. Which statistic to compute is a judgment call, seeded in `pgfr_record.rollup_specs(source_view, stat_name, agg, value_expr, predicate_sql)` for fourteen of Group C's fifteen targets, the same maintenance posture as `column_classes`' own override list. The exception, `pg_stat_wal_receiver`, needs no entry: its own LSN odometer columns make it mechanically eligible for the endpoint shape instead, the same rule Group B uses. `generate_rollups()` checks `rollup_specs` before `column_classes`, so a target's explicit hand-picked stat always wins over an incidental odometer column (e.g. `pg_stat_replication` and `pg_replication_slots` also carry LSN odometers, but keep the stat shape their own `rollup_specs` rows specify).

`rollup_specs` is deliberately threshold-free: `value_expr`/`agg` compute a continuous quantity, such as a duration in seconds via `extract(epoch FROM ...)`, or a count of samples in a structurally-defined state, never a pre-thresholded boolean. A cutoff like "longer than 5 minutes" is `pgfr_analyze`'s opinion to apply at read time against the stored value, not `pgfr_record`'s to decide once at capture time.

`generate_rollups()` creates each rollup table (`pgfr_record.r_<short_name>`) and its initial partitions, using the same retention-to-width rule as archive tables, against `rollup_retention` rather than `retention`. `generate_capture_plan()` mints each rollup-enabled target's bucket-close aggregate as `capture_plan.rollup_close_sql`, reading from the target's presentation view rather than its raw payload, so mid-major schema accretion is handled by the view's own `UNION`/`NULL`-fill rather than reimplemented here.

`run_tier()` closes eligible buckets on every tick, per target, in its own subtransaction separate from the raw capture: a rollup failure can never roll back an already-succeeded capture, and gets no ledger row either way (`health_check()`, below, surfaces it instead). It self-heals over a bounded range, every closed bucket between the oldest one still covered by the target's own raw retention and the most recently closed one, not just the bucket immediately before now, so a real gap (an outage shorter than retention) is recovered from on the next tick rather than silently skipped forever. A candidate bucket with no raw data at all, such as a fresh install's "yesterday", is left alone rather than recorded as a spurious "zero observed".

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

Example:

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

### `latest_state(source_view, t)`

The true-current-state sibling of `state_as_of()`, for non-debounced (Group A/C) targets only: every row at the single most recent `captured_at` within `t`'s partition, rather than per-key LOCF. Same calling convention as `state_as_of()` (`SETOF record`, caller-supplied column-definition list). Raises if called on a debounced target, where a missing row means unchanged rather than gone, and `state_as_of()` is the correct choice instead.

The distinction matters because a non-debounced target (`pg_stat_activity`, `pg_locks`, the progress views, and the rest of Group A/C) fully recaptures its entire current row set on every tick, with one `captured_at` shared by the whole tick (the single-stamp rule). A key that has since vanished, such as a backend that disconnected, has no future row to ever supersede its last one; `state_as_of()`'s LOCF would keep returning that stale row as if it were still current for as long as it remains within the partition bound (up to an hour, for Group C's hourly partitions). `latest_state()` avoids this by construction: every row it returns shares the single most recent `captured_at`, so a vanished key simply isn't there.

Confirmed against a live install: a backend captured once mid-transaction, then disconnected, still reads as an active idle-in-transaction backend under `state_as_of()` for the rest of that hour, but correctly disappears under `latest_state()`. `pgfr_analyze.long_running_transactions()`, `vacuum_progress()`, and `anomaly_report()`'s `IDLE_IN_TRANSACTION`/`LOCK_CONTENTION`/`CONNECTION_LEAK`/`REPLICATION_LAG`/`REPLICATION_SLOT_INACTIVE` checks all use `latest_state()` for exactly this reason.

### `resolve_relation(oid, t)` / `resolve_index(oid, t)`

Join through the catalog identity dimension (`pgfr_record.src_catalog_identity`, captured as a Group D target) as of `t`, surviving OID reuse across DROP/CREATE. Mechanically identical to each other, since `pg_class` covers every relkind including indexes; named separately only so a caller resolving an `indexrelid` doesn't have to know that. `t` defaults to `clock_timestamp()`, matching a live lookup when no historical point is given.

```sql
SELECT * FROM pgfr_record.resolve_relation('pgfr_record.manifest'::regclass::oid);
--         captured_at         |  oid  | relname  | relnamespace |   nspname   | relkind | relispartition | relfrozenxid | relminmxid | reltuples
-- 2026-08-28 22:44:09.447148+00 | 17563 | manifest |        17562 | pgfr_record | r       | f              |          726 |          1 |        -1
```

A nonexistent OID returns zero rows, not an error.

### `deltas(source_view, from_t, to_t)`

Consecutive-sample differences per key over counter/odometer columns, driven by `column_classes`, built directly on `state_as_of()`: join the `to_t` snapshot to the `from_t` snapshot by key, then difference. **Reset-aware**: a decreased counter value, or its linked `reset_column` advancing, yields `NULL` for that interval, never a negative rate. Odometers skip reset detection entirely (that's their definition). A key present at `to_t` but absent at `from_t` is excluded, not fabricated (an inner join on both snapshots). Raises on a keyless source view (there's no identity to correlate two points in time) and on an unknown source view.

Returns `SETOF record`; counter/odometer columns come back as `<column>_delta` (note: `pg_lsn - pg_lsn` yields `numeric`, so an LSN odometer's delta column is `numeric`, not `pg_lsn`); everything else passes through as the `to_t` value under its own name, plus `from_captured_at` and `to_captured_at`.

Example, two `pg_stat_wal` captures about 9 seconds apart:

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

### `rollup_deltas(source_view, from_bucket, to_bucket)`

The long-horizon analog of `deltas()`, for endpoint-shaped (Group B) rollup targets only: diffs the `last_values` of the bucket containing `to_bucket` against the `first_values` of the bucket containing `from_bucket`, per key. Reset-aware in exactly the same way `deltas()` is: a decreased value, or an advanced linked `reset_column`, yields `NULL` rather than a bogus delta. Raises for a stat-shaped (Group C) target, whose rollup rows are already the final per-bucket value with nothing left to difference; read `pgfr_record.r_<name>` directly instead.

Same `SETOF record` / caller-supplies-a-column-definition-list calling convention as `deltas()`:

```sql
SELECT relid, seq_scan_delta, seq_tup_read_delta, from_bucket, to_bucket
FROM pgfr_record.rollup_deltas('pg_catalog.pg_stat_all_tables', :from_bucket, :to_bucket)
    AS d(relid oid, seq_scan_delta bigint, seq_tup_read_delta bigint, ..., from_bucket timestamptz, to_bucket timestamptz);
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

`pgfr_record.apply_profile(profile_name)` reschedules the four tier jobs to the named profile's cadence and bounds, dispatching each as the two-statement `SET statement_timeout; SELECT run_tier(...)` command described above. It never touches the manifest. `cron.job`'s live schedule and command are the single source of truth for which profile is currently applied. `pg_cron` accepts a literal `"N seconds"` schedule syntax for sub-minute jobs, used by `troubleshooting`'s tighter fast cadence.

`pgfr_record.enable()` applies the `default` profile and schedules the hourly `maintain_partitions()` job: the single "turn pgfr_record on" operation. `pgfr_record.disable()` unschedules the four tier jobs and the maintenance job; archive data, the manifest, and the capture plan are untouched. Both are idempotent, and both explicitly set `active = true` on every job they schedule, since `cron.schedule()` on an already-scheduled job updates its schedule and command but leaves `active` at whatever it already was.

## `health_check()`

`pgfr_record.health_check()` returns `(check_name, status, detail)` rows covering:

- **`cron_job: <tier>` / `cron_job: maintenance`**: is the job scheduled and active.
- **`last_capture: <tier>`**: when the tier last finished, judged against that tier's own live schedule (read back from `cron.job`, not a hardcoded assumption) rather than a fixed threshold.
- **`ledger_miss_rate_1h`**: the fraction of captures in the last hour that didn't come back `ok`.
- **`partitions: <table>`**: does every pgfr-owned partitioned table have at least two widths of partitions ahead of now, and zero expired-but-still-attached partitions.
- **`rollup: <source_view>`**: for every rollup-enabled target, does its most recently closed bucket have a row yet. Only flagged when that bucket actually has raw data to roll up: a bucket with no raw data at all (a fresh install's "yesterday") reads `ok`, not `attention`, the same distinction `run_tier()`'s own bucket-close step makes.

Every check is read-only and threshold-free in the judgmental sense: each is a fixed structural fact (is a job scheduled, is a partition still attached past retention), never an opinion about what's normal. Opinions are `pgfr_analyze`'s job.

`health_check()` is read-only: every check reads a structural fact (`cron.job`, the ledger, `pg_inherits`) and writes nothing. It runs successfully inside a hard `READ ONLY` transaction, which is a stronger guarantee than declaring the function `STABLE`, since PostgreSQL checks a function's declared volatility against its own literal body only, not against what it calls transitively.

## `pgfr_analyze`

`pgfr_analyze` reads `pgfr_record`'s captured data, column classes, and definitional helpers to answer questions requiring a threshold, baseline, or opinion; it never writes to `pgfr_record`'s schema. Everything in `pgfr_record` has exactly one correct answer; everything below encodes a judgment call instead, tunable in most cases via `pgfr_analyze.config`. Most functions build their query dynamically against `pgfr_record.deltas()`, `pgfr_record.state_as_of()`, or `pgfr_record.latest_state()`, using an internal helper (`_deltas_col_defs()` / `_state_col_defs()`, the latter shared by both `state_as_of()` and `latest_state()` since they return the same column shape) to generate the caller-supplied column-definition list those functions require; a function built this way raises if the source view has no `pgfr_record.payload_schemas` row yet (that is, `pgfr_record` hasn't captured it even once) rather than silently returning nothing.

### Configuration

`pgfr_analyze.config(key, value, updated_at)` holds tunable thresholds (severity bands, lookback windows, ratios) for the functions below that expose one; `pgfr_analyze._get_config(key, default)` reads a key, falling back to the caller's own default when the key is unset. `pgfr_record` has no equivalent table: opinions belong here.

### Coverage and gaps

`pgfr_analyze.coverage(from_t, to_t)` (or `coverage(window)`, ending now) reports expected vs. observed tier runs per cadence tier, built directly on `pgfr_record.ledger_runs`. The expected count comes from each tier's live pg_cron schedule (via `pgfr_record._cron_schedule_to_interval()`), not a hardcoded assumption, and is `NULL` when a tier has no scheduled job:

```
 cadence_tier | expected_runs | observed_runs | coverage_ratio
--------------+---------------+---------------+----------------
 fast         |          60.0 |             6 |          0.100
 medium       |          12.0 |             5 |          0.417
 on_change    |          12.0 |             5 |          0.417
 slow         |           4.0 |             5 |          1.250
```

A `coverage_ratio` above 1.0 (as with `slow` above) means more runs landed in the window than the current schedule alone would predict, e.g. right after a profile change; it isn't an error condition.

`pgfr_analyze.coverage_gaps(from_t, to_t)` (or `coverage_gaps(window)`) finds contiguous runs of missed tier ticks, grouped via the standard `row_number()`-offset islands-and-gaps technique, each tagged with an `attributed_reason` (`cron_inactive` when the tier's job is missing or inactive, `unknown` otherwise). A tier with no resolvable schedule at all reports the entire queried window as one gap rather than being silently omitted. Per-target capture failures within a run that did happen are not gaps: query `pgfr_record.ledger_captures` directly for those (`outcome <> 'ok'`).

### Configuration tracking

Three functions, all built on `pgfr_record.state_as_of()` against `pg_settings`'s already-debounced Group D history, so GUC change detection needs no dedicated snapshot table:

- **`config_changes(from_t, to_t)`**: GUCs whose setting or source differ between the state as of `from_t` and as of `to_t`. `changed_at` is the actual capture timestamp of the `to_t` value, not a precisely detected change moment. Because `state_as_of()` returns zero rows before any capture existed, a window whose `from_t` predates the recorder's first `on_change`-tier capture reports every currently-set GUC as "changed" (`old_setting` `NULL`) rather than a small, real diff; anchor `from_t` after the recorder has had at least one debounce anchor cycle to run for a meaningful result. Correlating a config change against the counter/gauge behavior around it, once raw retention has passed, is what [Rollups](#rollups) are for.
- **`config_at(t, name_prefix)`**: GUC values as of `t` (LOCF), optionally filtered to names starting with `name_prefix`.
- **`config_health_check()`**: opinionated checks against the *live* (not historical) `pg_settings`: low `shared_buffers` (under 128MB), low `work_mem` (under 16MB), high `max_connections` (over 200), no `statement_timeout` set. Zero rows when nothing is flagged.

### Query dictionary and query-level analysis

`pgfr_analyze.query_dict(queryid, dbid, userid, toplevel, query_text, first_seen, last_seen)` is a deduplicated queryid-to-query-text table, refreshed from `pgfr_record.v_pg_stat_statements` by `refresh_query_dict()`. Because `pg_stat_statements` is a debounced Group B target, `pgfr_record` already recaptures the full row (query text included) whenever any of its counters change; the dictionary exists so analyze-side readers can get query text without re-scanning the archive. `first_seen` is never advanced on conflict, so it can't drift forward just because retention dropped the archive rows that would let it be recomputed from scratch.

`detect_regressions(lookback, threshold_pct)` and `detect_query_storms(lookback, threshold_multiplier)` both compare a recent window against a baseline window offset by `regression_baseline_days` / `storm_baseline_days` (default 7 days earlier), built on `pgfr_record.deltas('pg_stat_statements', ...)`:

- **`detect_regressions()`**: queries whose average execution time or buffer usage per call (`regression_detection_metric`: `time` or `buffers`, default `buffers`) worsened by more than `threshold_pct` (default 50%), requiring at least 5 calls in both windows. Severity bands (`regression_severity_low/medium/high_max`) are tunable via config.
- **`detect_query_storms()`**: queries whose call rate in the recent window exceeds baseline by more than `threshold_multiplier` (default 3x), classified `RETRY_STORM` (query text matches `retry`/`for update`, always CRITICAL), `CACHE_MISS` (no baseline calls, or over 10x baseline, a fixed constant rather than config-driven), `SPIKE` (over the threshold multiplier), else omitted.

### xmin horizon

Every raw xid these functions need is already captured on the fast tier (Group C): `pg_stat_activity.backend_xmin`, `pg_stat_replication.backend_xmin`, `pg_replication_slots.xmin`/`catalog_xmin`, `pg_prepared_xacts.transaction`. Deciding *which* of several xids is the dominant holder is a judgment call, so that resolution happens entirely here rather than inside the collector.

- **`xmin_horizon_history(from_t, to_t)`**: the single oldest (worst) xmin observation per source (`activity`, `replication`, `slot`, `slot_catalog`, `prepared`) captured in the window. `xmin_age` is `age(xid)` evaluated *now*, against the current transaction counter (the only counter PostgreSQL exposes), so it reflects each captured value's distance from the current horizon, not its age as of its own capture time; for that reason this is one row per source, not a per-tick timeline.
- **`current_xmin_horizon_holder()`**: the single dominant holder as of the most recent fast-tier capture, ties broken slot > prepared > activity > replication. Zero rows when the most recent capture has no candidate in any source. Always returns the current holder regardless of how old it is; applying a threshold to call that concerning is `anomaly_report()`'s job.

### Anomaly detection

`anomaly_report(from_t, to_t)` returns every flagged anomaly across a fixed but growing set of checks, each built on `pgfr_record.deltas()` (rate/count checks) or a current-state read via `latest_state(to_t)` (gauge checks over non-debounced Group A/C targets: `IDLE_IN_TRANSACTION`, `LOCK_CONTENTION`, `CONNECTION_LEAK`, `REPLICATION_LAG`, `REPLICATION_SLOT_INACTIVE`) or `state_as_of(to_t)` (the debounced Group B/D checks: dead-tuple and wraparound distance), never on a new capture:

| anomaly_type | basis | trigger (severity escalates past the second figure where one is given) |
|---|---|---|
| `FORCED_CHECKPOINTS` | delta | any forced (non-timed) checkpoint in the window |
| `CHECKPOINT_WRITE_TIME_HIGH` | delta | cumulative checkpoint write time over 10s (HIGH past 30s) |
| `BUFFER_PRESSURE` | delta | backends wrote over 100 of their own dirty buffers (HIGH past 1000) |
| `BACKEND_FSYNC` | delta | any backend-forced fsync |
| `TEMP_FILE_SPILLS` | delta | over 100MiB spilled to temp files across all databases (HIGH past 1GiB) |
| `IDLE_IN_TRANSACTION` | state @ `to_t` | idle in transaction over 5 minutes (HIGH past 30 minutes) |
| `LOCK_CONTENTION` | state @ `to_t` | waiting on a lock over 10 seconds (HIGH past 1 minute) |
| `CONNECTION_LEAK` | state @ `to_t` | over 20 backends idle (not in a transaction) for over an hour (HIGH past 50 backends) |
| `DEAD_TUPLE_ACCUMULATION` | state @ `to_t` | a relation is over 20% dead tuples and has over 1000 dead tuples (HIGH past 50%) |
| `VACUUM_STARVATION` | state @ `to_t` | over 10,000 dead tuples and never vacuumed, or not vacuumed in 7+ days (HIGH if never vacuumed or over 100,000 dead tuples) |
| `REPLICATION_LAG` | state @ `to_t` | a replica's `replay_lag` over 30 seconds (HIGH past 5 minutes) |
| `REPLICATION_SLOT_INACTIVE` | state @ `to_t` | any inactive replication slot (always HIGH) |
| `XID_WRAPAROUND_RISK` / `MXID_WRAPAROUND_RISK` | state @ `to_t` | a database over 200M transactions/multixacts past its frozen horizon (HIGH past 1.5B) |
| `RELATION_XID_WRAPAROUND_RISK` / `RELATION_MXID_WRAPAROUND_RISK` | state @ `to_t` | same, per ordinary table, materialized view, or TOAST relation |

Two of these checks read whichever view, column names, and shape actually apply on the running major, via `pgfr_record._current_major()`, rather than assuming one:

- **Checkpoint activity**: PG15/16 read `checkpoints_req`/`checkpoint_write_time` off `pg_stat_bgwriter`; PG17+ reads `num_requested`/`write_time` off `pg_stat_checkpointer`, where checkpoint columns moved.
- **Backend buffer pressure**: PG15/16 read `buffers_backend`/`buffers_backend_fsync` straight off `pg_stat_bgwriter`; PG17+ removes both columns, so the same signal comes from summing `writes`/`fsyncs` across every `client backend` row in `pg_stat_io` instead.

Most thresholds above are fixed constants, not currently config-driven. `LOCK_CONTENTION` deliberately stops at flagging the wait itself (`wait_event_type = 'Lock'`); identifying the blocking session is forensics work via `pg_locks` joined to `pg_stat_activity` by `pid` at equal `captured_at`, out of scope for a threshold check.

### Capacity summary

`capacity_summary(from_t, to_t)` reports utilization against a provisioned or reference capacity for each resource dimension `pgfr_record` actually captures, one row per dimension with data in the window (a dimension with no evidence in the window is simply absent, not zero):

| metric | current_usage | provisioned_capacity | status thresholds |
|---|---|---|---|
| `connections` | peak concurrent backends, summed across databases at each capture tick | `max_connections` | critical at 90%+, warning at 60%+ |
| `memory_shared_buffers` | backend-written buffers in the window (version-split the same way as `BUFFER_PRESSURE` above) | `shared_buffers` | same 1000-buffer HIGH reference as `anomaly_report()` |
| `memory_work_mem` | bytes spilled to temp files | `work_mem` | same 1GiB HIGH reference as `anomaly_report()`'s `TEMP_FILE_SPILLS` |
| `io_buffer_cache` | cache hit ratio across all databases | target 95%+ | critical under 80%, warning under 95% |
| `transaction_rate` | total commits + rollbacks / window seconds | workload dependent, informational only | warning at 5000+ tps |

Buffer-pressure and temp-spill reference points intentionally match `anomaly_report()`'s own thresholds, so the two functions stay consistent with each other.

### Self overhead

`self_overhead(from_t, to_t)` is the recorder measuring its own perturbation with the same discipline it applies everywhere else. Every figure is self-measured, not assumed:

| metric | source | window-relative? |
|---|---|---|
| `<tier>_ms_per_tick` | `avg(finished_at - captured_at)` over `pgfr_record.ledger_runs` rows for that tier | yes |
| `recorder_block_share` | the recorder's own schemas' share of total block hit/read traffic, from `pg_statio_all_tables` deltas | yes |
| `storage_bytes` | `sum(pg_total_relation_size)` over ordinary and materialized relations in `pgfr_record`/`pgfr_analyze` (includes indexes and TOAST) | no; live at call time, bounded by each target's manifest retention, so it converges rather than growing without limit |
| `pgss_time_share` | pgfr-attributed `total_exec_time` (statements whose text references a `pgfr_` schema) over all `total_exec_time`, in `pg_stat_statements` | no; live since its last reset, and only present when the extension is installed |

A metric is absent from the result, rather than zero or NULL, when the window or the live state holds no evidence for it (a fresh install, or `pg_stat_statements` not installed). Example, from a lightly loaded test instance:

```
        metric         |  value   |    units
-----------------------+----------+--------------
 fast_ms_per_tick      |      7.6 | milliseconds
 medium_ms_per_tick    |     19.7 | milliseconds
 on_change_ms_per_tick |      6.9 | milliseconds
 slow_ms_per_tick      |      6.6 | milliseconds
 storage_bytes         |  5218304 | bytes
 pgss_time_share       | 0.746070 | fraction
```

### Preflight check

`preflight_check()` covers live-catalog readiness for installing and enabling `pgfr_record`, independent of any captured history (there may be none yet); it complements `pgfr_record.health_check()`, which verifies ongoing operational health once running. Six checks, each with a `GO`/`CAUTION`/`NO-GO` verdict:

- **System Resources**: `max_worker_processes` (`CAUTION` below 4).
- **Connection Headroom**: current connections as a percent of `max_connections` (`CAUTION` at 70%+).
- **pg_stat_statements Budget**: `pg_stat_statements.max` (`CAUTION` below 5000, or if the extension isn't configured at all; once running, that one target's captures fail in isolation via the capture ledger without affecting any other tier).
- **Storage Overhead**: always `GO`; retention is partition-based, not a fixed footprint. Measure the real number after enabling with `self_overhead()`'s `storage_bytes`.
- **Scheduling (pg_cron)**: `NO-GO` if the extension is missing, a hard install-time dependency that `pgfr_record/install.sql` itself refuses to proceed without.
- **Safety Mechanisms**: always `GO`; describes the per-target capture-ledger isolation and the real, preemptive `statement_timeout` `apply_profile()` dispatches per tier run.

`preflight_check_with_summary()` appends a `=== SUMMARY ===` row: `NO-GO` if any check is `NO-GO`, else `PROCEED WITH CAUTION` if any is `CAUTION`, else `READY`.

### Check alerts

`check_alerts()` is an opinionated escalation layer over `pgfr_record.health_check()`'s own facts: `health_check()` reports structural facts against fixed thresholds, judgment-free by design, and `check_alerts()` turns every non-`ok` row into an alert with a severity and a recommendation:

| alert_type | source `health_check()` row | severity |
|---|---|---|
| `CRON_JOB_MISSING` | `cron_job: <tier or maintenance>` | CRITICAL |
| `STALE_DATA` | `last_capture: <tier>` | CRITICAL if never captured, else WARNING |
| `CAPTURE_FAILURES` | `ledger_miss_rate_1h` | WARNING |
| `PARTITION_MAINTENANCE_NEEDED` | `partitions: <table>` | WARNING |

Plus one alert with no `health_check()` counterpart: `STORAGE_SIZE_HIGH` (WARNING; live `pg_total_relation_size` over `pgfr_record`/`pgfr_analyze` at 8000 MiB or more). Takes no parameters: `health_check()`'s own ledger-miss window is already fixed at 1 hour, and the storage read is live. Empty when everything is healthy.

### Quarterly review

`quarterly_review()` is a 90-day-lookback health grade across six components, meant to be run periodically rather than continuously:

1. **Collection Performance**: worst (highest) average tier tick duration, from `ledger_runs` directly (not `self_overhead()`, which needs a minted `pg_statio_all_tables` payload schema this review doesn't otherwise require). EXCELLENT below 200ms, GOOD below 500ms, else REVIEW NEEDED; ERROR if no tier ran at all in 90 days.
2. **Storage Consumption**: live schema size. EXCELLENT below 3000MiB, GOOD below 6000MiB, else REVIEW NEEDED.
3. **Collection Reliability**: non-`ok`, non-`skipped_disabled` outcomes over 90 days (a deliberately disabled target isn't a failure). EXCELLENT at zero, GOOD below 10, else REVIEW NEEDED.
4. **Data Freshness**, 5. **pg_cron Job Health**, 6. **Partition Maintenance**: graded directly from `pgfr_record.health_check()`, grouped by `check_name` prefix (`last_capture:`, `cron_job:`, `partitions:` respectively).

`quarterly_review_with_summary()` appends a `=== QUARTERLY REVIEW SUMMARY ===` row: `ACTION REQUIRED` if any component graded `ERROR`, `REVIEW NEEDED`, or `CRITICAL`, else `HEALTHY`.

### Table hotspots

`table_hotspots(from_t, to_t)` runs four fixed threshold checks over `pg_stat_all_tables` deltas in the window; a table can appear more than once if it trips more than one check:

| issue_type | trigger |
|---|---|
| `SEQUENTIAL_SCAN_STORM` | over 100 sequential scans reading over 100,000 tuples |
| `TABLE_BLOAT` | over 20% dead tuples |
| `LOW_HOT_UPDATE_RATIO` | over 1000 updates, under 50% via HOT |
| `HIGH_AUTOVACUUM_FREQUENCY` | over 5 autovacuum runs in the window |

### Index analysis

Both functions are built on `pg_stat_all_indexes` deltas. Index size is never a `pg_stat_*` counter or gauge, so both read it live via `pg_relation_size(indexrelid)` at call time rather than from a capture.

- **`unused_indexes(lookback)`** (default 7 days): indexes with fewer than 100 scans over the lookback, excluding primary keys, ordered by current size descending. Recommends `DROP INDEX` at zero scans, "consider dropping" under 10, otherwise "keep".
- **`index_efficiency(from_t, to_t, limit)`** (default limit 25): the busiest indexes by scan delta, with `selectivity` (`idx_tup_fetch_delta` as a percent of `idx_tup_read_delta`; low means many index entries read per row actually fetched) and `scans_per_gb`.

### Activity readers

Three thin presentation functions, each over a single source:

- **`vacuum_progress(t)`** (default now): in-flight `VACUUM` operations as of `t`, via `latest_state()` (not `state_as_of()`: a finished vacuum must actually disappear, not carry forward as a stale row). `relname` is resolved through `resolve_relation()` since only `relid` is captured directly on `pg_stat_progress_vacuum`. `pct_dead_tuple_buffer` collapses PG15/16's tuple-count tracking (`num_dead_tuples`/`max_dead_tuples`) and PG17+'s byte-based tracking (`dead_tuple_bytes`/`max_dead_tuple_bytes`) into one version-stable fill percentage. Verified live against an in-flight `VACUUM` on PG17 (`scanning heap`, 56.0% scanned, 1.9% dead-tuple buffer); PG15's branch is the same computation over the pre-PG17 column names. All three percentages are `NULL` before their denominator is known.
- **`wal_archiver_status(from_t, to_t)`**: archiving throughput and failures over the window, from `pg_stat_archiver` deltas. `last_archived_wal`/`last_archived_time`/`last_failed_wal`/`last_failed_time` are the archiver-reported end-of-window values, not window-relative.
- **`long_running_transactions(t, threshold)`** (default now, 5 minutes): any backend whose transaction has been open longer than `threshold` as of `t`, regardless of state, via `latest_state()` (not `state_as_of()`: a disconnected backend must actually disappear, not carry forward as a false long-running transaction); broader than `anomaly_report()`'s `IDLE_IN_TRANSACTION` check, which only flags idle ones.

### Composing reports

Three functions compose everything above for a window `[from_t, to_t]`:

- **`performance_report(lookback)`** (default 24 hours): the recorder's own performance, with two things `self_overhead()` doesn't provide: per-tier *max* duration (not just avg), and a before/after trend split (the window's first half vs. second half, on the fast tier, since it's the most data-rich for a split), graded DEGRADING/STABLE/IMPROVING.
- **`summary_report(from_t, to_t)`**: a structured `(section, metric, value, interpretation)` table composing `coverage()`, `anomaly_report()`, `capacity_summary()`, `table_hotspots()`, `unused_indexes()`, `long_running_transactions()`, `vacuum_progress()`, `wal_archiver_status()`, and `config_changes()`, under sections OVERVIEW / CAPACITY / TABLES & INDEXES / ACTIVITY / CONFIGURATION. The machine-readable counterpart to `report()`.
- **`report(from_t, to_t)`** (or `report(lookback)`, ending now): a human- and AI-legible markdown rendering of the same functions plus `coverage_gaps()`, `index_efficiency()`, `detect_regressions()`, and `detect_query_storms()`, as prose with one markdown table per section. Lock-wait forensics beyond `anomaly_report()`'s `LOCK_CONTENTION` check and `long_running_transactions()`, and role-level configuration changes (which would need a `pg_db_role_setting` capture `pgfr_record` does not have), are out of scope.

Example header and one section, from a live test instance:

```
# pg_flight_recorder Report

**Generated:** 2026-08-29 00:54:24 UTC
**Range:** 2026-08-28 23:54:24 to 2026-08-29 00:54:24
**Coverage:** 14/60.0 fast (23.3%), 5/12.0 medium (41.7%), 6/12.0 on_change (50.0%), 5/4.0 slow (125.0%); 8 tier(s) with missed ticks (see coverage_gaps())
Coverage is below 90% for at least one tier in this window; conclusions below are qualified accordingly.

## Vacuum Progress

| Database | Table | Phase | Scanned | Vacuumed | Dead Tuple Buffer |
|----------|-------|-------|---------|----------|-------------------|
| postgres | t_demo | scanning heap | 56.0% | 0.0% | 1.9% |
```
