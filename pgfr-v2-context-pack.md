# pg_flight_recorder v2 — Context Pack

**Audience:** Claude Code, implementing pgfr v2 from scratch in this repository.
**Status:** Design is CLOSED. This pack is the specification. Do not re-litigate settled decisions; where judgment is needed, two items are explicitly flagged `VERIFY-DURING-IMPLEMENTATION`.
**Compatibility stance:** v2 is a clean-slate install. Same project name (pgfr), same schemas (`pgfr_record`, `pgfr_analyze`). No migration or import path from v1 archives. v1 code is reference material only.
**Targets:** PostgreSQL 15, 16, 17, 18 (19 eventually). PG15 is the floor; PG14 is out of scope. Must run on stock PostgreSQL and on Supabase (no true superuser).
**Dependencies:** pg_cron (required). pg_stat_statements (optional, manifest-gated). Nothing else — pgfr maintains its own partitions (§4.2); do not add pg_partition_magician or any other partition-management dependency, as pgfr's needs (pre-create calendar-regular empty partitions ahead, drop expired ones behind) are deliberately simple enough to handle in-house.

---

## Contents

- [1. Kernel statement](#1-kernel-statement)
- [2. Vocabulary](#2-vocabulary)
- [3. Manifest DDL + PG15 seed census](#3-manifest-ddl--pg15-seed-census)
  - [3.1 DDL](#31-ddl)
  - [3.2 PG15 seed census (~30 enabled rows)](#32-pg15-seed-census-30-enabled-rows)
- [4. Physical layout + generator behavior](#4-physical-layout--generator-behavior)
  - [4.1 Archive tables](#41-archive-tables)
  - [4.2 Partitioning and retention](#42-partitioning-and-retention)
  - [4.3 Generator (installer) behavior](#43-generator-installer-behavior)
  - [4.4 Payload dictionary (dictionary-encoded samples)](#44-payload-dictionary-dictionary-encoded-samples)
  - [4.5 Definitional helpers (in `pgfr_record`, per the agent test)](#45-definitional-helpers-in-pgfr_record-per-the-agent-test)
  - [4.6 Self-observation](#46-self-observation)
- [5. Collection algorithm](#5-collection-algorithm)
- [6. Debounce / anchor specification](#6-debounce--anchor-specification)
- [7. Version-drift policy](#7-version-drift-policy)
- [8. Security posture, capture ledger, and the no-adaptive-safety stance](#8-security-posture-capture-ledger-and-the-no-adaptive-safety-stance)
  - [8.1 The stance (design claim, verbatim into user docs)](#81-the-stance-design-claim-verbatim-into-user-docs)
  - [8.2 Capture ledger](#82-capture-ledger)
  - [8.3 Privilege degradation](#83-privilege-degradation)
- [9. Non-goals (state loudly, in README and in this pack)](#9-non-goals-state-loudly-in-readme-and-in-this-pack)
- [10. Acceptance criteria + cost model](#10-acceptance-criteria--cost-model)
  - [10.1 Acceptance criteria](#101-acceptance-criteria)
  - [10.2 Cost model (documented curve, not runtime mechanism)](#102-cost-model-documented-curve-not-runtime-mechanism)
- [Appendix: implementation order (suggested milestones, not pre-sliced issues)](#appendix-implementation-order-suggested-milestones-not-pre-sliced-issues)

---

## 1. Kernel statement

> **pgfr_record appends debounced, dictionary-encoded jsonb samples of PostgreSQL's own stats views and system views into time-partitioned tables, and drops old partitions.**

That single clause is the entire write path and the entire retention story. Everything else in `pgfr_record` is machinery driven by a manifest: which views, how often, with what identity, kept how long.

The conceptual pitch, which every doc surface should repeat: PostgreSQL's cumulative stats system gives you the **integral**; the system catalogs give you the **latest**. pgfr gives you the **derivative** over the stats and the **history** over the catalog. The data model is not designed — it is *inherited*: it is exactly the tables and views documented in the PostgreSQL manual (Monitoring Stats + System Views chapters), presented as a time series.

Structural invariants (violating any of these is a design regression, not a bug fix):

1. **Append-only everywhere.** No UPDATE, no DELETE, anywhere in `pgfr_record`. State history is event-sourced (changed rows + periodic anchors), never SCD-2 interval-closing.
2. **No judgment in the record layer; all definition in the record layer.** The boundary is definitional vs. judgmental, and it is tested by the **agent test**: *could an AI agent with a dump of `pgfr_record` alone, restored into a separate database, with psql, make progress on troubleshooting?* Everything with a single correct answer belongs in `pgfr_record`: what was captured (manifest), what shape it has (payload dictionary), what kind of quantity each column is (column classes: counter/odometer/gauge/label, reset linkage), how identity resolves across time (OID resolution over the catalog identity dimension), and what mechanical transforms mean (as-of/LOCF, reset-aware deltas). Everything requiring a threshold, baseline, or opinion belongs in `pgfr_analyze`: anomaly/regression/storm detection, trends, capacity judgments, recommendations, reports. Raw cumulative samples only — deltas are computed lazily by definitional helpers and are never stored.
3. **One storage mechanism.** There is no ring buffer as a distinct architecture. Short retention *is* the ring: every capture target is an append-only, RANGE-partitioned table whose retention is implemented as partition drop. Retention is a number in the manifest, not a storage kind.
4. **No adaptive safety mechanisms.** No circuit breaker, no load shedding. Static bounds only (`lock_timeout`, per-view `statement_timeout`, job timeout < tier interval), plus a capture ledger that records every miss with its reason. Rationale in §8.
5. **Record is sufficient; analyze is acceleration.** A record-only install (or dump) is fully self-contained and self-describing: typed presentation views (regenerable offline from the payload dictionary, on any PG major, with no live source views), column-class legend, identity resolution, definitional helpers, generated COMMENTs on every object so `\d+` self-documents. `pgfr_analyze` is strictly optional: it reaches conclusions faster, but nothing an agent needs to reach them lives only there. The moment a record-layer function would need a notion of "normal," it belongs in analyze.

---

## 2. Vocabulary

- **Manifest** — the table `pgfr_record.manifest`; the single design artifact. One row per capture target. All generator and collector behavior is a pure function of the manifest.
- **Capture target / source view** — a stats view, system view, or catalog projection listed in the manifest (e.g. `pg_catalog.pg_stat_database`).
- **Archive table** — the per-manifest-row storage table, uniform shape across all targets, RANGE-partitioned on `captured_at`.
- **Presentation view** — a generated view in `pgfr_record` that projects an archive table's jsonb payloads back into the source view's typed columns plus `captured_at`. Regenerated per major version at install/upgrade.
- **Cadence tier** — `fast | medium | slow | on_change`. Manifest rows reference tiers; profiles map tiers to intervals. One pg_cron job per tier.
- **Sample** — one appended row: the state of one source-view row at one `captured_at`.
- **Debounce** — skipping the append of a row whose content is unchanged since its most recent capture (per natural key, within the anchor window).
- **Anchor** — a periodic unconditional full capture of a debounced target (all rows appended regardless of change). Distinguishes "unchanged" from "not observed"; bounds LOCF reconstruction; aligns to partition boundaries.
- **Capture ledger** — the per-run, per-target outcome record (`ok | timeout | lock_timeout | denied | error`) plus visibility level. Misses are telemetry, not silence.
- **LOCF** — last-observation-carried-forward: reconstructing "state as of time t" for debounced targets by taking each key's most recent sample ≤ t (never reaching left past one anchor).
- **Profile** — a named mapping of tiers → intervals plus the timeout bounds. v2 profiles reduce to *cadence + bounds* (v1's safety posture is gone). Ship `default` and `troubleshooting`.
- **Size class** — coarse cardinality label per target (`singleton | per_db | per_relation | per_backend | per_slot`), used only by the cost model and docs.
- **Counter / odometer / gauge / label** — column-class taxonomy recorded in `pgfr_record.column_classes` (the legend; see invariant 2 and §3.1): counters are monotone + resettable (derivative is the value prop); odometers are monotone + non-resettable (LSNs, XIDs; no reset detection needed); gauges are point-in-time; labels are identity/dimensions. `pgfr_record` stores and describes the taxonomy and applies it only in definitional helpers (§4.5); it never judges with it.
- **Agent test** — the record/analyze boundary test: an AI agent with a `pgfr_record`-only dump, a separate database, and psql must be able to make troubleshooting progress. Definitional = record; judgmental = analyze. Operationalized as acceptance criterion 11.

---

## 3. Manifest DDL + PG15 seed census

### 3.1 DDL

```sql
CREATE TABLE pgfr_record.manifest (
  source_view     text PRIMARY KEY,        -- schema-qualified, e.g. 'pg_catalog.pg_stat_database'
  min_major       int  NOT NULL DEFAULT 15,
  max_major       int,                     -- NULL = still present
  cadence_tier    text NOT NULL CHECK (cadence_tier IN ('fast','medium','slow','on_change')),
  natural_key     text[] NOT NULL DEFAULT '{}',  -- {} = singleton; NULL-equivalent identity handled by keyless flag below
  keyless         boolean NOT NULL DEFAULT false, -- true = no stable identity (pg_locks); debounce must be false
  debounce        boolean NOT NULL DEFAULT false,
  compare_ignore  text[] NOT NULL DEFAULT '{}',  -- columns nulled (by position, via §4.4 dictionary) in the compare payload before row-hashing; stored intact
  anchor_every    interval,                -- NULL unless debounce; see §6 for partition alignment rule
  retention       interval NOT NULL,       -- implemented as partition drop
  logged          boolean NOT NULL DEFAULT true, -- false => UNLOGGED partitions (tuning knob; default logged)
  size_class      text NOT NULL CHECK (size_class IN ('singleton','per_db','per_relation','per_backend','per_slot')),
  requires        text,                    -- precondition: extension name, GUC setting, or role/privilege note
  enabled         boolean NOT NULL DEFAULT true,
  notes           text,
  CHECK (debounce = false OR anchor_every IS NOT NULL),
  CHECK (keyless = false OR debounce = false)
);
```

Projection targets (catalog identity set) are expressed as manifest rows whose `source_view` names a pgfr-defined view (e.g. `pgfr_record.src_catalog_identity`) created by the installer as a projection over `pg_class`/`pg_namespace`. The manifest mechanism is uniform; the projection is just another source.

**Column-class legend lives in `pgfr_record`** (moved from analyze by the agent test — it is a legend, i.e. catalog, the same species as the payload dictionary): `pgfr_record.column_classes(source_view, column_name, class CHECK (class IN ('counter','odometer','gauge','label','key','dict')), reset_column text)`, seeded by the installer from §3.2's notes. Without it, a record-only dump forces an agent to re-derive PostgreSQL documentation facts empirically. `pgfr_analyze` consumes it; it does not own it.

### 3.2 PG15 seed census (~30 enabled rows)

Tier defaults refer to the `default` profile: fast = 1 min, medium = 5 min, slow = 15 min, on_change = 5 min (the *check* cadence; writes occur only on change or anchor).

**Group A — cumulative counters, singleton / per-db.** durable-length retention (30 days), fast tier, debounce = false (cheap, always changing, every sample wanted).

| source_view | key | size_class | retention | notes / analyze metadata |
|---|---|---|---|---|
| pg_stat_archiver | {} | singleton | 30d | reset: stats_reset |
| pg_stat_bgwriter | {} | singleton | 30d | reset: stats_reset. PG17 removes checkpoint columns (moved to pg_stat_checkpointer); agnostic capture absorbs |
| pg_stat_wal | {} | singleton | 30d | reset: stats_reset |
| pg_stat_slru | {name} | singleton | 30d | per-cache row set; reset: stats_reset |
| pg_stat_database | {datid} | per_db | 30d | includes datid=0 shared-objects row; reset: stats_reset |
| pg_stat_database_conflicts | {datid} | per_db | 30d | nonzero only on standbys |

**Group B — cumulative counters, per-relation.** The cardinality frontier. medium tier (statio: slow), debounce = true, anchor_every = 1 day, retention 30d, compare_ignore = estimate-churn columns.

| source_view | key | compare_ignore | requires | notes |
|---|---|---|---|---|
| pg_stat_all_tables | {relid} | {n_live_tup, n_dead_tup, n_mod_since_analyze, n_ins_since_vacuum} | — | ignore-list prevents estimator churn from defeating debounce; ignored cols still stored |
| pg_stat_all_indexes | {indexrelid} | {} | — | |
| pg_statio_all_tables | {relid} | {} | — | slow tier |
| pg_statio_all_indexes | {indexrelid} | {} | — | slow tier |
| pg_statio_all_sequences | {relid} | {} | — | slow tier |
| pg_stat_user_functions | {funcid} | {} | track_functions ≠ none | |
| pg_stat_statements | {userid, dbid, queryid, toplevel} | {} | pg_stat_statements extension | dict: query (analyze-side dictionary over queryid → text). Reset via pg_stat_statements_info.stats_reset. Eviction-aware: a vanished queryid is eviction, not reset. Also capture pg_stat_statements_info as its own singleton row (add manifest row, fast tier). |

**Group C — gauges.** fast tier, retention 2h (this *is* the v1 ring, expressed as a retention number), debounce = false.

| source_view | key | keyless | size_class | notes |
|---|---|---|---|---|
| pg_stat_activity | {pid, backend_start} | no | per_backend | backend_start disambiguates pid reuse; dict: query (analyze-side) |
| pg_locks | — | yes | per_backend | no stable identity; join to activity via pid at equal captured_at (exact — see §5 single-stamp rule) |
| pg_stat_replication | {pid} | no | per_slot | odometers: sent_lsn, write_lsn, flush_lsn, replay_lsn |
| pg_stat_wal_receiver | {} | no | singleton | standby-side; odometers on received LSNs |
| pg_stat_subscription | {subid} | no | per_slot | |
| pg_replication_slots | {slot_name} | no | per_slot | odometers: restart_lsn, confirmed_flush_lsn; *failure to advance* is the alarm (analyze-side) |
| pg_prepared_xacts | {gid} | no | singleton | usually empty; an aging row is itself an anomaly |
| pg_stat_progress_vacuum | {pid} | no | per_backend | default-on: empty view costs one SELECT |
| pg_stat_progress_cluster | {pid} | no | per_backend | default-on |
| pg_stat_progress_create_index | {pid} | no | per_backend | default-on |
| pg_stat_progress_basebackup | {pid} | no | per_backend | default-on |
| pg_stat_progress_analyze | {pid} | no | per_backend | default-on |
| pg_stat_progress_copy | {pid} | no | per_backend | default-on |

**Group D — state history.** on_change tier, debounce = true, anchor_every = 1 month (anchors align to partition width — §6 — and Group D uses monthly partitions per the §4.2 width rule; LOCF over ≤1 month is trivial at these cardinalities), retention 365d, logged = true always.

| source_view | key | notes |
|---|---|---|
| pg_settings | {name} | flagship: GUC change detection falls out of debounce for free |
| pg_roles | {oid} | strip rolpassword from payload defensively (masked anyway) |
| pg_hba_file_rules | {line_number} | requires: privileged read; degrade via ledger |
| pg_file_settings | {sourcefile, sourceline} | detects applied-vs-file divergence; privileged |
| pg_extension | {oid} | catalog table, not a view; extension installs/upgrades |
| pgfr_record.src_catalog_identity (projection over pg_class ⋈ pg_namespace: oid, relname, relnamespace, nspname, relkind, relispartition) | {oid} | **the dimension table**: resolves any relid/indexrelid in Group B *as of* any captured_at, surviving OID reuse across DROP/CREATE |

**Group E — enabled = false rows (present in manifest with reasons, so "why doesn't pgfr capture X" is queryable):**

| source_view | reason |
|---|---|
| pg_cursors | session-local: observes pg_cron's session, not the workload |
| pg_prepared_statements | session-local |
| pg_backend_memory_contexts | session-local (PG15 form); candidate for troubleshooting profile in later PG majors |
| pg_timezone_names | static and enormous |
| pg_stats | per-column planner statistics: huge, ANALYZE-cadenced, a different product |
| pg_shmem_allocations | low routine value; candidate troubleshooting-profile extra |

**Version rows beyond PG15** (seeded now, activated by introspection per §7):

| source_view | min_major | group | notes |
|---|---|---|---|
| pg_stat_io | 16 | A (fast, 30d, {backend_type, object, context} key) | the single most valuable addition in the series |
| pg_stat_checkpointer | 17 | A (singleton) | receives the columns split out of pg_stat_bgwriter |

Census summary: ~31 enabled PG15 rows — 6 Group A, 7+1 Group B (incl. pg_stat_statements_info), 14 Group C, 6 Group D — plus 6 disabled rows and 2 version-gated rows.

---

## 4. Physical layout + generator behavior

### 4.1 Archive tables

One archive table per enabled manifest row, generated by the installer. **Uniform shape** — this is what "schema-agnostic" means; the schema is identical everywhere, only the tables are plural:

```sql
CREATE TABLE pgfr_record.a_<short_name> (
  captured_at timestamptz NOT NULL,
  key         jsonb,            -- natural_key columns extracted: {"relid": 16384}; NULL when keyless or singleton
  key_hash    bigint,           -- hashtextextended(key::text, 0); NULL when key IS NULL
  row_hash    bigint NOT NULL,  -- see §6
  schema_id   smallint NOT NULL REFERENCES pgfr_record.payload_schemas,  -- which column layout this row uses (§4.4)
  payload     jsonb NOT NULL    -- jsonb ARRAY of values, positional per schema_id; NOT an object (§4.4)
) PARTITION BY RANGE (captured_at);
```

`<short_name>` = source view name without schema (e.g. `a_pg_stat_database`). No visibility column here — visibility lives in the capture ledger (§8), per run per target, not per row.

Rationale for plural tables over one giant generic table: retention becomes per-target partition dropping; a 100k-relation Group B table cannot bloat pg_settings history; autovacuum sees homogeneous tables; TOAST behavior is per-target tunable; and per-target indexes stay small. The generator makes all of them from the manifest, so plurality costs no hand-written DDL.

Indexes per archive table (created on partitions via the parent): `(captured_at)` implied by partitioning; `(key_hash, captured_at DESC)` for the debounce anti-join and LOCF; nothing on payload.

### 4.2 Partitioning and retention

- RANGE partitions on `captured_at`. Partition width derived from retention by rule (not a manifest column): retention ≤ 6h → hourly; ≤ 60d → daily; > 60d → **monthly**. Rationale: width must scale with retention at both ends — hourly for gauges keeps ~5 live partitions each; monthly for long-retention state targets avoids ~2,200 near-empty daily partitions cluster-wide. Steady-state census ≈ 550 partitions total; ~670 create/drop ops/day, nearly all on the cheap gauge tables — well inside normal catalog-churn tolerance.
- Retention = `ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY` (SHARE UPDATE EXCLUSIVE on the parent — never blocks collectors) followed by DROP of the detached table. **Mandatory, not optional**: plain DROP of an attached partition takes ACCESS EXCLUSIVE on the parent, and a drop *queued* behind any reader queues everything behind it in turn — the classic declarative-partitioning production footgun. **Constraint that shapes the mechanism below**: `DETACH PARTITION ... CONCURRENTLY` cannot be executed inside a transaction block, and Postgres enforces this even inside a function or procedure body (`ERROR: ALTER TABLE ... DETACH CONCURRENTLY cannot be executed from a function` — confirmed against the Postgres manual and a pgsql-hackers thread; there is no `CALL`/procedure workaround). It must be dispatched as pg_cron's own literal top-level job command, never invoked from inside `maintain_partitions()` directly — see below. Archive and ledger tables must never be given a DEFAULT partition (also disallowed under `CONCURRENTLY`). The maintenance job runs under the same `lock_timeout` as the collectors; a maintenance run that cannot acquire its lock records a ledger miss and retries next cycle. **No DELETE statements exist in pgfr.**
- Partition maintenance is **in-house**: `pgfr_record.maintain_partitions()`, run by its own pg_cron job (hourly). Because `DETACH ... CONCURRENTLY` cannot run inside its own function body, maintenance is a small hourly state machine rather than a linear script:
  1. **Create-ahead** — for each archive/ledger table, pre-create partitions covering at least two partition widths beyond `now()`. Ordinary DDL; runs directly inside the function.
  2. **Schedule detaches** — for each partition whose upper bound is older than `now() - retention` and still attached, `cron.schedule()` a one-off pg_cron job (named per partition) whose command text is *only* the bare `ALTER TABLE parent DETACH PARTITION child CONCURRENTLY` statement. Nothing else may share that command string: a multi-statement command dispatched in one message is wrapped in an implicit transaction by the simple query protocol, which would break `CONCURRENTLY` all over again. Give the job an **exact one-time cron spec** (a specific minute/hour/day/month, not a recurring wildcard pattern) so it fires exactly once by construction, firing within the next minute, rather than retrying every minute and spamming "already detached" errors if reaping is ever delayed. `cron.schedule()` itself is an ordinary insert into `cron.job`, safe to call from inside `maintain_partitions()`.
  3. **Drop retired tables** — for each standalone table left over from a prior cycle's detach (no longer present in `pg_inherits`, matching pgfr's naming convention), `DROP TABLE`. Ordinary DDL: the table is no longer attached to anything, so this carries none of the parent-locking risk above.
  4. **Reap** — `cron.unschedule()` the one-off detach jobs scheduled in step 2 once their target partition has confirmed left `pg_inherits`.

     A partition's full retirement therefore spans up to two maintenance cycles (schedule → detach fires within a minute → next hourly cycle drops the table and reaps the job), immaterial given retention windows measured in hours to months and create-ahead already buffering two widths. All four steps touch only pgfr-owned, empty-at-birth or expired-at-drop partitions — no data movement, no attach of live tables, no locking subtleties beyond the brief ACCESS EXCLUSIVE on the specific partition being created or dropped, which never contends with collectors for more than one tick. Still pg_cron only — no new dependency. Partition maintenance is the only moving part besides the collectors.
- Insert-time backstop: if a collector's INSERT would land outside existing partitions (maintenance job died), the per-target EXCEPTION block records the miss in the ledger (`error`, detail = no partition); `health_check()` surfaces maintenance staleness. Do not add an on-demand-creation trigger path — that is precisely the complexity this decision avoids.
- Design note (record in README design notes): a pgque-style fixed-table TRUNCATE ring was considered and rejected for the archive. pgque's motivating pathology — dead tuples and xmin pinning from per-row queue deletion — does not exist here under either option (partition drop is the same relfilenode-level zero-bloat class as TRUNCATE). What remains is recycle-vs-replace, and the read model decides it: a queue is read by coordinated cursors and never by ad-hoc SQL, while pgfr's archive exists *for* ad-hoc time-range SQL — RANGE-on-captured_at gives planner pruning on the predicate every query naturally uses, a single logical table per target, exact retention semantics, and zero rotation state (no pointer, no epoch hazard, no consumer-safety check). The ring's one real advantage — writes survive maintenance death — is mitigated by create-ahead ≥2 widths plus ledger-visible failure, and its failure mode (silent retention stretch) is the invisible-degradation grammar this design rejects. TRUNCATE-recycling remains a candidate for v2.1 rollup tables, whose small fixed-size fully-rewritten shape actually fits it.
- `logged = false` targets get UNLOGGED partitions. Default is logged; unlogged is a documented tuning knob with the documented trade: unlogged samples vanish on crash, which is precisely when you wanted them.

### 4.3 Generator (installer) behavior

The installer is a set of plpgsql generator functions, pure functions of the manifest + the server's actual catalog:

1. `pgfr_record.generate_archives()` — for each enabled manifest row where `min_major <= current_major <= coalesce(max_major, 999)`: create the archive table if absent and pre-create its initial partitions (via `maintain_partitions()`); fingerprint the live source view and mint the payload_schemas row + capture statement together (§4.4).
2. `pgfr_record.generate_presentation_views()` — for each such row: introspect the *live* source view's column list (`information_schema.columns` / `pg_attribute`) and emit:

```sql
CREATE OR REPLACE VIEW pgfr_record.v_<short_name> AS
SELECT captured_at,
       (jsonb_populate_record(NULL::pg_catalog.<source_view>, payload)).*
FROM pgfr_record.a_<short_name>;
```

   With array payloads, generation is always the explicit positional form, driven by the dictionary: `(payload->>0)::bigint AS datid, (payload->>1)::text AS datname, ...` per the target's current schema_id (CASE over schema_ids when multiple shapes exist within the current major). Positions are fragile for humans; no human ever writes them — the generator owns both sides (mint-together invariant, §4.4). Presentation views reflect the **current major only** (§7).
3. `pgfr_record.generate_capture_plan()` — materializes, per tier, the ordered list of (source_view, timeout, debounce, anchor) the collector iterates. Regenerated whenever the manifest changes.

Re-running the installer is always safe and is the upgrade procedure (§7).

### 4.4 Payload dictionary (dictionary-encoded samples)

Payloads are **jsonb arrays of values in a fixed positional order**, not objects. Rationale: in an object encoding, an all-numeric stats row spends ~65–70% of its bytes repeating key names (~500B of structure vs ~220B of values for pg_stat_all_tables), most payloads sit *below* the TOAST/compression threshold so the repeated keys are never even compressed, and the tax is paid twice — heap and WAL. jsonb arrays keep jsonb's heterogeneous container (compact `numeric` for counters, native null, text only where text exists) and shed exactly the structural tax. Expected ≈2.5× reduction on the dominant cost-model term. Native typed arrays (`int8[]` etc.) were rejected: views are type-heterogeneous, forcing either numbers-as-text or parallel arrays split by type class — coordinated fragments that debounce, presentation, and the generator would all have to reassemble.

The positional order lives once, in the dictionary:

```sql
CREATE TABLE pgfr_record.payload_schemas (
  schema_id   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_view text NOT NULL,
  columns     text[] NOT NULL,      -- position i of payload = columns[i+1]
  type_names  text[] NOT NULL,      -- drives presentation-view cast generation
  fingerprint text NOT NULL,        -- hash of (source_view, columns, type_names)
  first_seen  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_view, fingerprint)
);
```

Append-only like everything else: a changed view shape is a new row, never an edit. Written only by the generator; read by the generator (presentation views) and by anyone reading raw payloads.

**Mint-together invariant (the one corruption hazard positional encoding introduces, closed):** the generated capture statement and its `schema_id` are two outputs of one generator run, minted atomically — the INSERT's `jsonb_build_array(...)` column order and the dictionary row are never independently editable. The capture plan caches the current schema_id per target; the generator re-fingerprints live views at plan (re)generation. Arrays cannot distinguish NULL from absent — every position is always present, NULL-filled — which is fine *because* the schema_id says exactly which columns exist for that row.

Mid-major column additions (pg_stat_statements is the known offender) are handled per-row and exactly: rows carry the schema_id they were captured under; presentation views CASE on schema_id within the current major. This makes schema identity explicit per row — strictly more drift-robust than object payloads, where shape is implicit.

**Honest concession (state in user docs):** the stored payload is no longer literally "the view's row as an object" — it is the view's row, *normalized* (keys dictionaried out, exactly as query text already is). The doc-fidelity promise — "the data model is exactly the PostgreSQL views" — is made and kept at the presentation layer, which is the only layer users read.

### 4.5 Definitional helpers (in `pgfr_record`, per the agent test)

Mechanical, deterministic, threshold-free functions over recorded facts — semantics-as-arithmetic, one correct answer each:

- `pgfr_record.state_as_of(source_view, t)` — LOCF reconstruction per §6: for each key, the most recent sample ≤ t, bounded by the containing anchor. Returns presentation-view shape.
- `pgfr_record.resolve_relation(oid, t)` / `resolve_index(oid, t)` — join through the catalog identity dimension *as of* t; OID-reuse-safe by construction. The dimension data without its join method is a riddle; the method is definitional.
- `pgfr_record.deltas(source_view, from_t, to_t)` — consecutive-sample differences per key over counter/odometer columns (per `column_classes`), **reset-aware**: value decreased, or the linked reset column advanced → NULL for that interval, never a negative rate. Odometers skip reset detection.
- Generated `COMMENT ON` for every archive table, presentation view, and column (text derived from the dictionary + column classes + manifest notes), so psql `\d+` is self-documenting — the discovery channel an agent actually uses.

Explicitly *not* here: anything needing a baseline or threshold (anomaly, regression, storm, trend, capacity opinion, recommendation, `report()`). Those are `pgfr_analyze`.

### 4.6 Self-observation

pgfr's own schema appears in its own Group B captures. Keep it: free health telemetry. Rows are trivially identifiable via the presentation view (`WHERE schemaname = 'pgfr_record'` on `v_pg_stat_all_tables`; on raw payloads, by the schemaname position per schema_id); `pgfr_analyze` excludes them by default with an opt-in parameter.

---

## 5. Collection algorithm

One pg_cron job per cadence tier (four jobs), **not** per view — 30+ jobs would pollute `cron.job` and the observed `pg_stat_activity`. Plus one maintenance job running `pgfr_record.maintain_partitions()` hourly (§4.2). Pseudocode for a tier job:

```
run_tier(tier):
  SET LOCAL lock_timeout = profile.lock_timeout             -- e.g. 100ms -- correctly re-armed per statement, see below
  SET LOCAL statement_timeout = profile.job_timeout(tier)   -- best-effort only when run_tier() is the sole statement in its
                                                              -- dispatch -- see "the statement_timeout arming gotcha" below
  t0 := clock_timestamp()                                   -- ONE captured_at per invocation
  run_id := nextval(pg_get_serial_sequence('pgfr_record.ledger_runs', 'run_id'))  -- reserved; ledger_runs row itself
                                                                                    -- is appended once, at the end (§8.2)
  FOR target IN capture_plan(tier) ORDER BY manifest order:
    IF clock_timestamp() - t0 >= profile.job_timeout(tier) THEN EXIT END IF  -- cooperative deadline check, see below
    BEGIN                                                    -- per-target EXCEPTION block (subtransaction)
      SET LOCAL lock_timeout = profile.lock_timeout          -- re-affirmed every iteration; real per-target enforcement
      IF target.debounce AND NOT anchor_due(target, t0) THEN
        INSERT INTO archive(target)
        SELECT t0, key, key_hash, row_hash, schema_id, payload
        FROM   hashed_rows(target)
        WHERE  (key_hash, row_hash) NOT IN last_seen(target, anchor_window(t0))   -- §6 anti-join
      ELSE
        INSERT ... SELECT t0, ... FROM hashed_rows(target)   -- full capture (anchor, or non-debounced)
      END IF
      ledger.record_capture(run_id, target, 'ok', rows, visibility(target))
    EXCEPTION
      WHEN lock_not_available  THEN ledger.record_capture(run_id, target, 'lock_timeout')
      WHEN query_canceled      THEN ledger.record_capture(run_id, target, 'timeout')
      WHEN insufficient_privilege THEN ledger.record_capture(run_id, target, 'denied')
      WHEN others              THEN ledger.record_capture(run_id, target, 'error', sqlerrm)
    END
  INSERT INTO pgfr_record.ledger_runs (run_id, tier, captured_at, finished_at)   -- single append, not open+close (§8.2)
  OVERRIDING SYSTEM VALUE VALUES (run_id, tier, t0, clock_timestamp())
```

**The `statement_timeout` arming gotcha (discovered during milestone 6 acceptance testing, correcting the pseudocode above as originally drafted):** confirmed against a live server that `statement_timeout`'s enforcement timer is armed once, at the start of the current *top-level* statement, using whatever value was in effect at that moment. A `SET`/`SET LOCAL statement_timeout` executed *from inside* that same top-level statement's own execution — including via a nested `EXECUTE` inside a called function — does **not** retroactively re-arm the already-running timer; it only takes effect for a genuinely later top-level statement. Since `run_tier()` is invoked as a single top-level call (`SELECT pgfr_record.run_tier(...)`, whether by pg_cron or by hand), **every internal `SET LOCAL statement_timeout` inside the function body as originally drafted was a no-op** — neither `job_timeout` nor a per-target `section_timeout` ever actually bounded anything. `lock_timeout` does **not** share this defect: a lock wait is checked dynamically against whatever `lock_timeout` is currently in effect at the moment the wait begins, so `SET LOCAL lock_timeout` from inside a called function works exactly as originally intended, per-target, confirmed against a live server. This changes the design as follows:

- **`lock_timeout` is the real, working, per-target defense** against §8.1's primary named risk (queuing behind an ACCESS EXCLUSIVE lock). No change needed to how it's set.
- **`section_timeout` is dropped as a per-target statement-level bound.** There is no way to preemptively cancel one target's slow-but-not-lock-blocked query from inside a `run_tier()` loop using pure SQL/PL/pgSQL; doing so would require dispatching each target as its own literal top-level statement (e.g. via `dblink`/`pg_background`), which contradicts §0's "nothing else" dependency stance and the already-settled "one job per tier, not per view" decision. `profile_tiers` retains only `lock_timeout` and `job_timeout`.
- **`job_timeout` is enforced two ways, deliberately overlapping:** (a) a **cooperative deadline check** at the top of the per-target loop — before starting a *new* target, `run_tier()` checks whether the tier's elapsed time already exceeds `job_timeout` and exits the loop without starting further targets if so (any target skipped this way simply has no `ledger_captures` row for the run, detectable by comparing against `capture_plan`); and (b) when `run_tier()` is invoked as the second statement in a two-statement dispatch — `SET LOCAL statement_timeout = 'Xms'; SELECT pgfr_record.run_tier(...)`, which is how `apply_profile()` now constructs every tier's `cron.job` command — the *caller's* `SET`, issued as its own preceding top-level statement, genuinely arms preemptive cancellation for the whole call, catching a target that is not merely slow but truly hung. (a) works unconditionally, including manual/interactive invocation; (b) is the real backstop when running under cron. Together these still deliver on the intent of "`job_timeout(tier) < tier_interval(tier)`" (§10.1 acceptance criterion 6, enforced by the `profile_tiers` CHECK constraint) even though the mechanism differs from the original pseudocode.

Load-bearing details:

- **Single stamp.** `t0` is stamped once per invocation and shared by every target in the tier. Cross-view joins at equal `captured_at` (pg_locks ⋈ pg_stat_activity) are therefore exact, not approximate.
- **Atomic capture.** Each target's capture is a single `INSERT ... SELECT`. A timeout aborts it atomically: no partial captures, no cleanup, nothing to repair. Append-only makes kill -9 of a collector backend consequence-free.
- **Failure isolation.** One target's lock-queue hang, permission failure, or error cannot fail the tier. The ledger row *is* the handling.
- **Ledger is a single append per run, not open-then-close.** The whole tier run is one transaction (the per-target blocks are subtransactions within it), so nothing is visible to any other session until it commits regardless of when within the loop a row is written. `run_id` is therefore reserved up front via `nextval`, `ledger_captures` rows are written per target as the loop executes, and the single `ledger_runs` row is appended once at the end with both `captured_at` and `finished_at` already known — never an UPDATE, consistent with invariant 1's "no UPDATE, anywhere." A crash mid-run leaves no `ledger_runs` row at all rather than one stuck half-open; `cron.job_run_details` (pg_cron's own log) is the source of truth for "did the top-level call itself error or overrun."
- **Overrun protection** is the invariant `job_timeout(tier) < tier_interval(tier)` — enforced by a CHECK constraint on `profile_tiers` when profiles are applied, and delivered at runtime by the two-part mechanism above. This replaces the circuit breaker (§8).
- `VERIFY-DURING-IMPLEMENTATION №1` — **RESOLVED (milestone 6):** pg_cron serializes overrunning jobs; it does not launch concurrent/overlapping instances. Confirmed against a live pg_cron instance (the SHA pinned in this repo's Dockerfile) by scheduling a job on a 5-second interval whose body sleeps 12 seconds: successive invocations started at :23, :35, :47, :59 — each starting almost exactly when the *previous* invocation finished, never overlapping, using a fresh backend PID each time. A missed tick is silently absorbed (the job resumes as soon as the running instance completes), not queued or run concurrently. This makes the `job_timeout(tier) < tier_interval(tier)` invariant sufficient on its own: even under a pathological, sustained overrun, pgfr never accumulates piled-up concurrent collector backends for the same tier.
- The on_change tier is mechanically identical to the others — it is merely the tier where every target has debounce = true, so most invocations append nothing.

---

## 6. Debounce / anchor specification

**Row hashing.** `row_hash = hashtextextended(compare_payload::text, 0)` where `compare_payload` = the payload array with `compare_ignore` *positions* nulled out (generator translates the manifest's column names to positions; the stored payload keeps all values). Canonicality is trivial by construction: arrays are ordered, and the order is fixed by the schema_id — no reliance on jsonb object-key sorting. Two payloads hash equal iff same schema_id and same values at compared positions; include schema_id in the compared text so a shape change always registers as a change (and is anyway followed by an anchor at the next partition boundary).

`VERIFY-DURING-IMPLEMENTATION №2` (reduced scope under array encoding): a sanity regression test that numeric formatting in `jsonb array ::text` serialization is stable for equal values across supported majors (e.g. no trailing-zero or exponent-notation drift for the same stored numeric), so equal rows hash equal on every major. Far weaker assumption than object-key canonicality; test it anyway.

**Anti-join.** "Changed" = the pair `(key_hash, row_hash)` does not match the target's most recent capture for that `key_hash` **within the current anchor window** (i.e., since the last anchor, inclusive). Implemented as a lateral/DISTINCT ON read of recent partitions — there is **no writable last-seen state table** (that would be UPDATE traffic, violating invariant 1). The `(key_hash, captured_at DESC)` index bounds this read.

**Hash-collision stance:** a 64-bit collision on the *same key* suppresses one changed sample until the next anchor repairs it. Accepted; documented; not defended against further.

**Anchors.** For every debounced target, an unconditional full capture:
- fires when `anchor_every` has elapsed since the target's last anchor, **and** whenever a new partition would otherwise open without one — rule: **anchor cadence = partition width** (daily for Group B, monthly for Group D, matching the §4.2 width rule), so *every partition opens with a full snapshot*.
- Consequences, both load-bearing: (a) LOCF reconstruction of "state as of t" never reads left of the containing partition's first rows by more than one partition; (b) any prefix of partitions can be dropped without dangling references — retention never orphans history.
- Anchors answer observability: a key absent since the last anchor was *observed absent* (dropped/idle-and-then-dropped is distinguishable via the catalog identity dimension); a missing *run* is visible in the ledger. "Unchanged," "gone," and "not observed" are three distinguishable states.

**Keyless targets** (pg_locks): debounce = false by CHECK constraint; every sample kept; identity questions are answered by joining to keyed views at equal captured_at.

**LOCF read pattern** (for pgfr_analyze and presentation-layer helpers): state of target as of `t` = for each key_hash, the most recent row with `captured_at <= t`, searched no further back than the anchor at or before `t`.

---

## 7. Version-drift policy

Agnostic capture makes version drift a *read-side* concern. Policy, one sentence per direction:

- **Columns added** (pg_stat_io in 16, checkpointer split in 17, pg_stat_statements accretion): absorbed silently by jsonb capture; presentation views regenerated per-major expose them; manifest rows carry `min_major`.
- **Columns removed/renamed:** old payloads keep old keys forever; presentation views target the **current major only**; cross-version historical reads are an analyze-side concern and **explicitly not guaranteed** in v2.
- **Views added:** a new manifest row with `min_major`; disabled rows document deliberate exclusions.
- **Views removed:** `max_major` set; archive tables and their history remain readable.

**Upgrade procedure:** after a PostgreSQL major upgrade, re-run the installer. It regenerates presentation views and the capture plan against the new catalog; archive tables and history are untouched. This is a selling point over v1 (state it in user docs).

pg19: expected to require nothing beyond new manifest rows when its view changes land; the mechanism is version-blind by construction.

---

## 8. Security posture, capture ledger, and the no-adaptive-safety stance

### 8.1 The stance (design claim, verbatim into user docs)

> pgfr v2 has **no adaptive safety mechanisms** — no circuit breaker, no load shedding. It has **static bounds** (`lock_timeout` per target, `job_timeout` per tier run) and a **capture ledger** that records every miss with its reason. The claim: bounded, recorded degradation is strictly better than adaptive shutdown for an instrument whose value peaks during incidents.

Rationale (for the README's design-notes section): adaptive mechanisms sense load and disable collection in response; load is correlated with incidents; therefore they systematically go dark exactly when data matters most — a flight recorder that shuts off during turbulence. They are also feedback loops with tunable thresholds and internal state: they can oscillate, be miscalibrated, and harbor bugs. The observer effect, meanwhile, cannot be engineered to zero because its tail is not in pgfr's code — a capture query can queue behind an ACCESS EXCLUSIVE lock (making pgfr a lock-convoy participant), hold a snapshot that pins the xmin horizon during a vacuum-debt incident, or contend on pg_stat_statements' internals during a query storm. The only lever on the tail is to **bound the wait**. `lock_timeout` converts unbounded lock-queue interference into a bounded, recorded miss, per target, always (§5's arming gotcha). Under duress the recorder degrades from telling you *what* is happening to telling you *that* something is happening ("pg_locks capture hit lock_timeout at 14:32, 14:33, 14:34" is a positive, timestamped observation of catalog contention). A breaker's limiting behavior is silence; the ledger's is coarser telemetry.

**Accepted residual risk (document, do not solve):** a target whose capture is slow for reasons *other* than lock contention (e.g. genuine CPU cost, not blocking) is not preemptively cancelled per-target when `run_tier()` is invoked as a bare top-level call (§5's arming gotcha) — only the cooperative `job_timeout` deadline check stops *further* targets from starting, and only a caller that dispatches `run_tier()` as the second statement in a `SET statement_timeout; SELECT run_tier(...)` pair (as `apply_profile()` now does for the cron path) gets genuine preemptive cancellation of that one stuck target. Under a sustained timeout storm, pgfr therefore wastes up to ~`job_timeout` of aborted-or-blocked query time per tick before the run gives up starting new targets, while capturing little. Still bounded by construction (never more than one `job_timeout` per tick, never a pile-up per VERIFY №1), and self-documenting in the ledger, minute by minute.

Mean observer effect is engineered out structurally: append-only (no pgfr-caused vacuum debt), debounce (write volume ∝ change, not catalog size), one job per tier (≈4 extra backends, constant), single-stamp captures (no re-reads), partition drop (no retention DELETEs). Remaining mean cost is the read side — Group B is O(relations) to read regardless of writes — governed by cadence tiers and the cost model (§10), not by runtime mechanisms.

### 8.2 Capture ledger

`ledger_runs` is written exactly once per run, after the tier's loop completes (§5) — never opened then closed. Open-then-close-with-an-UPDATE would be SCD-2 interval-closing applied to the one piece of state that looks mutable, which is precisely the pattern invariant 1 rules out ("event-sourced... never SCD-2 interval-closing"). Since the whole run is one transaction, nothing is visible to any other session until commit regardless of when a row is written, so there is no observability cost to deferring the insert — and a crash mid-run now simply leaves no row, rather than a row wedged with `finished_at IS NULL` forever.

```sql
CREATE TABLE pgfr_record.ledger_runs (
  run_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tier        text NOT NULL,
  captured_at timestamptz NOT NULL,          -- the tier's single stamp
  finished_at timestamptz NOT NULL           -- both timestamps known at insert time; no UPDATE, ever
) PARTITION BY RANGE (captured_at);          -- same mechanism, e.g. 30d retention

CREATE TABLE pgfr_record.ledger_captures (
  run_id      bigint NOT NULL,
  source_view text NOT NULL,
  outcome     text NOT NULL CHECK (outcome IN ('ok','timeout','lock_timeout','denied','error','skipped_disabled')),
  rows_appended int,
  was_anchor  boolean,
  visibility  text CHECK (visibility IN ('full','masked','degraded')),  -- per run per target, NOT per row
  detail      text,                          -- sqlerrm for 'error'
  elapsed     interval
) PARTITION BY RANGE (run_id);               -- or co-partition by captured_at via denormalized stamp; implementer's choice, append-only either way
```

The ledger is append-only like everything else and is itself subject to retention by partition drop. `pgfr_analyze` treats ledger misses as first-class telemetry (miss-rate views, "masked during this window" annotations instead of null-shaped lies).

### 8.3 Privilege degradation

Several targets are role-gated: full `pg_stat_activity.query` needs `pg_read_all_stats`; `pg_hba_file_rules` / `pg_file_settings` need privileged read; Supabase grants no true superuser. The collector **captures what it is allowed to see and records the visibility level** in the ledger — never fails the target for partial visibility, never fails the tier for a denied target. `requires` in the manifest documents preconditions; the installer surfaces unmet ones at install time as NOTICEs, not errors. Defensive strips (rolpassword) happen at capture regardless of visibility.

Grant posture: pgfr runs as the role that owns its schema; recommend (and document) granting `pg_read_all_stats` and, where available, `pg_read_all_settings` / `pg_monitor`. On Supabase, document the exact achievable visibility per target.

---

## 9. Non-goals (state loudly, in README and in this pack)

1. **Rollups / long-horizon aggregates.** Deferred to v2.1. Candidate mechanisms already chosen *against*: native materialized views (WAL churn, dead tuples). Candidates on the table for v2.1: rollup-to-partition tables, or TRUNCATE-rotated aggregate tables. Until then, retention is truncation and trending operates on the raw window.
2. **Multi-database capture.** pgfr observes the database it is installed in. Per-database views mean per-database installs; `pg_stat_database` retains cluster-wide-at-db-grain visibility. No dblink/bgworker gymnastics.
3. **v1 migration or import.** Clean slate. v1 archives are short-retention operational data, not heirlooms.
4. **Cross-version historical reads.** Presentation views target the current major; reading pre-upgrade payloads through post-upgrade views is best-effort, analyze-side.
5. **Planner statistics (pg_stats).** Different product.
6. **Stored derivatives/deltas.** Never. Raw cumulative samples are idempotent and let reset logic improve after the fact; baked deltas fossilize whatever reset handling existed at capture time.
7. **Adaptive safety mechanisms.** See §8; their absence is a feature with a rationale, not an omission.

Carried forward from v1 (user-facing surfaces with muscle memory):

- **`pgfr_record.health_check()`** — survives, v1-like shape, reinterpreted: pg_cron jobs active per tier, last capture per tier, ledger miss rate (1h), archive size vs. documented model, partition-maintenance status (partitions exist ≥2 widths ahead for every target; no expired partitions lingering).
- **Profiles** — survive, reduced to *cadence + bounds*: `default` (fast 1m / medium 5m / slow 15m / on_change 5m; `lock_timeout` 100ms every tier; `job_timeout` per tier, comfortably under its interval) and `troubleshooting` (fast 20s / medium 1m, tighter `job_timeout` to match). `section_timeout` does not appear here — see §5's arming gotcha for why it was dropped. `apply_profile(name)` remaps tiers and bounds; never touches the manifest.
- **`pgfr_analyze.report(window)`** — survives in analyze as markdown-for-LLM-triage, rebuilt over presentation views + ledger; explicitly not required for a record-only install to be useful.

---

## 10. Acceptance criteria + cost model

### 10.1 Acceptance criteria

1. **Install matrix:** clean install on stock PG 15, 16, 17, 18 and on Supabase; `SELECT pgfr_record.enable();` then `health_check()` returns all-green within two fast-tier intervals.
2. **Presentation fidelity:** for every enabled target, `v_<name>` column names and types match the live source view on that major (automated test: diff against `information_schema`).
3. **Debounce correctness:** synthetic workload touching a known subset of relations produces Group B appends for exactly that subset between anchors; anchors capture all rows; "as of t" LOCF reconstruction matches a direct snapshot taken at t.
4. **Ledger correctness:** induced `lock_timeout` (hold an ACCESS EXCLUSIVE lock on a captured catalog relation), induced `statement_timeout`, and a revoked privilege each produce the correct ledger outcome without failing the tier; other targets in the same run report `ok`.
5. **Crash safety:** `kill -9` / `pg_terminate_backend` on a collector backend mid-run leaves no partial capture visible (single-statement atomicity) and the next run proceeds normally. (Append-only makes this nearly free; assert it anyway.)
6. **Overrun invariant:** applying any profile enforces `job_timeout < tier_interval`; pg_cron overrun semantics verified and documented (VERIFY №1).
7. **Hash canonicality regression test** (VERIFY №2) passes on all supported majors.
8. **Upgrade drill:** pg_upgrade a test cluster 15→16 (and 16→17), re-run installer, verify pg_stat_io appears (16), checkpointer appears (17), history intact, presentation views regenerate.
9. **Partition maintenance:** after two maintenance-job intervals, every target has partitions ≥2 widths ahead and none past retention; disabling the maintenance job produces ledger `error` (no partition) misses rather than tier failures, and re-enabling it self-heals without intervention.
10. **Cost model conformance:** the synthetic workload's archive growth lands within ±50% of the model's prediction (the model is a planning tool, not a promise).
11. **The agent test (self-containment):** `pg_dump` the `pgfr_record` schema from the synthetic-workload instance; restore into an empty database on a *different* PG major; regenerate presentation views offline from `payload_schemas` (no live source views); verify that a psql-only session can answer a fixed troubleshooting question set — which relations grew fastest, what backends were waiting on at time t, when the recorder was blind (ledger), and which relation OID 16384 was (resolve_relation) — using no `pgfr_analyze` object. This criterion is the operational form of invariant 2.
12. **Storage-encoding benchmark:** capture a synthetic 1k-relation workload for 24h under object encoding and array encoding; report heap bytes and WAL bytes per target. Expected ≈2.5× reduction for array encoding on Group B. **Reopen clause:** if the measured win is under ~1.5×, escalate before proceeding — the dictionary is cheap but not free, and object encoding (with its simpler §6 story) would then deserve reconsideration.

### 10.2 Cost model (documented curve, not runtime mechanism)

Publish as an appendix with worked examples. Bytes/day per target ≈

```
rows_per_capture × captures_per_day × bytes_per_row
```

where for debounced targets `rows_per_capture = churn_rate × cardinality` between anchors, plus one full `cardinality` capture per anchor; `bytes_per_row` ≈ serialized jsonb *array* payload (measure per view; dictionary encoding removes the repeated-key tax of object payloads — see §4.4 and acceptance criterion 11).

Dominant terms to call out:
- **Group C / pg_stat_activity:** `max_connections × 1440/day × ~1 KB`, but retention is 2h, so steady-state size ≈ `max_connections × 120 × ~1 KB` — small.
- **Group B / per-relation:** the frontier. Steady-state ≈ `R × (anchor/day × 30d + churn × 288/day × 30d) × ~0.7 KB` for R relations at 5-min cadence. Worked examples at R = 500, 5,000, 100,000.
- **The 100k-relation backpressure statement (policy, verbatim):** pgfr does not adaptively defend against pathological relation counts. The cost curve is documented; at ~10⁵ relations, Group B cadence should be slowed or targets disabled in the manifest — and a schema with 10⁵ active relations has observability problems upstream of pgfr.

Self-measurement closes the loop: pgfr's own schema appears in its own captures, so `health_check()` compares actual archive growth against the model.

---

## Appendix: implementation order (suggested milestones, not pre-sliced issues)

1. Manifest DDL + PG15 seed + generators (archives, presentation views, capture plan) + `maintain_partitions()`.
2. Collector core: tier jobs, single stamp, EXCEPTION-block isolation, timeouts, ledger.
3. Debounce + anchors (+ VERIFY №2 regression test).
4. Definitional layer: `column_classes` seed, `state_as_of`/`resolve_relation`/`deltas`, generated COMMENTs.
5. Profiles + `enable()`/`disable()` + `health_check()`.
6. Acceptance suite (§10.1), including VERIFY №1 and the agent test (criterion 11).
7. `pgfr_analyze` v2 seed: anomaly/regression/storm detection, trends, capacity views, `report()` — all consuming `pgfr_record`'s column classes and definitional helpers (§4.5), owning none of them.

Hand this pack to Claude Code whole, with milestone 1 as the first instruction.
