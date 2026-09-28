# pgfr v2 Documentation Rewrite: Handoff

**Audience:** a fresh Claude Code session with no memory of the v2 implementation work. This document is self-contained; you should not need the prior conversation to do this job correctly.

**Task:** rewrite this project's documentation to describe pgfr v2 as it actually exists in the code today, in this exact order:

1. `REFERENCE.md`
2. `pgfr_record/README.md`
3. `README.md` (top level)
4. `STATISTICS.md` (a review-and-update pass, not necessarily a ground-up rewrite; see its section below for why this one is softer-scoped)

**Branch:** stay on `feat/pgfr-v2`. Do not create a new branch. This is a continuation of the same v2 rewrite effort that has been running on this one branch since the start (manifest, generators, collector, definitional layer, profiles, acceptance suite all landed here); the plan from the beginning was one dedicated branch and one eventual PR to `main`. Commit incrementally, one commit per file in the order above, following this repo's Conventional Commits / Conventional Branches conventions (already documented in this repo's `CLAUDE.md`).

---

## 1. What happened before this handoff

`pg_flight_recorder` just underwent a complete, clean-slate rewrite of `pgfr_record` (and a placeholder stub of `pgfr_analyze`) per `pgfr-v2-context-pack.md`, the design specification for v2. That pack's own header states the compatibility stance plainly: v2 is a clean-slate install, no migration path from v1, v1 code is reference material only.

**Every existing doc file in this repo (`REFERENCE.md`, `pgfr_record/README.md`, `README.md`, `STATISTICS.md`) describes v1** — ring buffers, snapshots, sparse collectors, circuit breakers, a fixed hand-written schema. None of that exists in the codebase anymore. The v1 SQL files were deleted (preserved in git history, not in the working tree); the v2 SQL files that replaced them have a completely different architecture: a manifest table drives everything, archive tables are uniform-shaped and dictionary-encoded, and generator functions build almost everything else from the manifest plus the live catalog. The current docs are not "a little stale" — they are wrong from the first paragraph on. Treat them as having zero authority over what to write; they exist purely as a structural reference for organization/tone if you find that useful, nothing more.

Milestones 1 through 6 of the v2 rewrite (per the pack's Appendix) are complete and merged into `feat/pgfr-v2`. Milestone 7 (`pgfr_analyze` v2) has **not** started — `pgfr_analyze` is currently an empty placeholder schema with one comment explaining that it's deferred. Do not describe `pgfr_analyze` capabilities that don't exist yet; describe it honestly as not yet rebuilt for v2, matching what the placeholder's own `COMMENT ON SCHEMA` already says.

---

## 2. Get oriented: read these first, in this order

1. **`pgfr_record/install.sql`** — its header comment is the authoritative index of every SQL file and what it contains, in load order. Read the 15 files it lists (`pgfr_record/sql/01_schema.sql` through `15_health_check.sql`) in full. This is ground truth for what pgfr_record actually is. It's not a large amount of code (a few thousand lines total across all 15 files); read all of it before writing anything.
2. **`pgfr_record/tests/*.sql`** (13 files, numbered to roughly match the sql/ files) — these are concrete, verified-passing examples of every piece of behavior. When you want to know "does X actually work the way I think," the test that exercises X is more trustworthy than prose (including this document).
3. **`pgfr-v2-context-pack.md`** — the design spec. Read it for the *rationale* (why append-only, why debounce, why the agent test matters, the cost model, the non-goals). But see §3 below: several places in this pack were corrected or superseded during implementation, and the pack itself has been updated in those spots — reread the corrected sections carefully, don't work from a stale mental model of "what the pseudocode originally said."
4. **`scripts/agent_test.sh`** — a working, self-contained demonstration of the "agent test" (dump `pgfr_record`, restore into a different PostgreSQL major, regenerate presentation views offline, answer troubleshooting questions via plain psql with no `pgfr_analyze` object). This is a real, tested feature worth documenting prominently — it's the operational proof of the record/analyze boundary.
5. **`git log --oneline main..feat/pgfr-v2`** (or just `git log` while on the branch) — every commit message on this branch narrates what was built and, importantly, what bugs were found and fixed along the way by testing against live PostgreSQL rather than trusting the design on paper. Several of those bugs are exactly the kind of subtle, easy-to-get-wrong behavior that documentation needs to describe correctly. Read the full commit messages, not just the subject lines.

Actually install pgfr_record while you work. The Docker test infrastructure (`./test.sh`, `docker-compose.yml` + the per-extension compose files) is already set up; bring up a `postgres15` container, install, and use `psql` (`\d+`, `\df+`, `\dv+`) against the live result as you write. Milestone 4 built a generated `COMMENT ON` system (`generate_comments()`) specifically so that `\d+` output is self-documenting — lean on it heavily. When you describe a table, function, or view, quote or closely paraphrase its actual live comment rather than reinventing a description; if what you'd write and what the comment says disagree, the comment (and the code it describes) wins, not your assumption.

---

## 3. Known corrections to pgfr-v2-context-pack.md

The pack is the design spec, but it was written before implementation, and implementation surfaced real corrections. The pack's own text has already been updated in most of these spots (search for the section references below), but they're listed here together because they're the highest-risk places for documentation to accidentally describe the *original, wrong* design instead of what actually shipped:

- **The capture ledger is a single append per run, never open-then-close.** `ledger_runs` gets exactly one `INSERT`, after a tier's capture loop finishes, with `run_id` reserved via `nextval` up front and both `captured_at`/`finished_at` already known. This was corrected before implementation even started (see §8.2).
- **`maintain_partitions()` is a four-step hourly state machine, not a simple linear script.** `DETACH PARTITION ... CONCURRENTLY` cannot execute from inside a function or procedure body (a real, confirmed PostgreSQL restriction, not a bug). The fix: schedule the literal `DETACH ... CONCURRENTLY` statement as a one-off `pg_cron` job (its own top-level statement), then a later maintenance cycle drops the now-standalone table and reaps the completed one-off job. See §4.2.
- **`pg_stat_statements` and `pg_stat_statements_info` are extension-provided views**, not `pg_catalog` builtins — they live wherever `CREATE EXTENSION` put them (`public` on stock PostgreSQL, typically `extensions` on Supabase), so the manifest references them unqualified and relies on `search_path` resolution. See `pgfr_record/sql/03_seed_pg15.sql`.
- **Presentation views are `DROP` + `CREATE`, never `CREATE OR REPLACE`.** PostgreSQL refuses to replace a view in a way that removes or reorders existing output columns, which a source view can legitimately do across majors (e.g. PG17 splitting checkpoint columns out of `pg_stat_bgwriter`). See `06_generators.sql`.
- **Array-typed columns need special handling when reconstructed from the jsonb payload.** The `->>` operator returns a nested array's JSON-bracket text form, not a Postgres array literal; `06_generators.sql`'s `_jsonb_element_cast()` handles this correctly via `jsonb_array_elements_text()`.
- **`column_classes` (the counter/odometer/gauge/label/key legend) is a generator, not a hand-typed seed list.** See `09_column_classes.sql` for the mechanical, type/name-driven ruleset and its documented override list. This matters for documentation: don't imply every column's classification was individually, manually verified against PostgreSQL's docs — it's a best-effort mechanical classification with a small, named set of known exceptions, and that honesty should show up in the docs the same way it shows up in the code comments.
- **The most significant correction — the `statement_timeout` arming gotcha.** Confirmed against a live server: `statement_timeout`'s enforcement timer is armed once, at the start of the current top-level SQL statement, and is **not** re-armed by a `SET`/`SET LOCAL statement_timeout` executed from inside that same top-level statement's own execution — including from inside a called function. Since `run_tier()` is itself invoked as one top-level call, every internal attempt to bound its own execution time this way was silently a no-op. `lock_timeout` does **not** share this defect (a lock wait is checked dynamically, confirmed against a live server), so it remains a real, per-target bound with no change needed. The corrected design, now implemented:
  - `lock_timeout`: unchanged, real, enforced per target.
  - `job_timeout`: enforced two ways — a cooperative deadline check inside `run_tier()` (stops the tier from *starting* further targets once the budget is spent; works unconditionally) and a genuine caller-side preemptive `SET`, since `apply_profile()` now dispatches every tier's `pg_cron` job as two top-level statements (`SET statement_timeout = ...; SELECT run_tier(...)`), which can actually cancel a target that's truly hung, not merely slow.
  - `section_timeout` (a per-target statement-level bound): **dropped entirely.** It cannot be implemented without dispatching each target as its own top-level statement, which would require a dependency (`dblink`/`pg_background`) the design deliberately does not take on. It does not exist in `run_tier()`'s signature or in `profiles`/`profile_tiers`. If you see it mentioned anywhere you're drafting, that's a sign you're working from stale context — remove it.
  See §5's "arming gotcha" writeup and §9 in the pack, and `08_collector.sql` / `13_profiles.sql` in the code.
- **`health_check()` is verified genuinely read-only, two ways, and this is documented for a specific reason: v1 had a real incident where `health_check()` internally ran `cleanup()`, which could itself fail or time out.** v2's `health_check()` was confirmed to complete successfully inside a hard `READ ONLY` transaction, and — importantly for how you write this up — declaring a function `STABLE` does **not**, on its own, prevent it from calling a mutating function; Postgres only checks a function's own literal body against its declared volatility, not what it calls. The `READ ONLY` transaction test is what actually proves the guarantee (confirmed separately that a real mutating call, forced to do work, fails loudly inside `READ ONLY`). This is worth a clear, specific callout in the docs — it's a direct answer to a real past incident, not a generic feature.
- **VERIFY №1 resolved:** `pg_cron` serializes overrunning jobs; it does not launch concurrent/overlapping instances of the same job. Confirmed against a live instance. Worth stating plainly wherever the docs discuss the overrun-protection story, since it's the empirical basis for why bounded timeouts are sufficient without a circuit breaker.
- `pg_cron` accepts a literal `"N seconds"` schedule syntax for sub-minute jobs (used by the `troubleshooting` profile's tighter cadence), confirmed working, not just assumed from documentation.
- `cron.schedule()` on an already-existing job updates its schedule/command but does **not** reactivate a previously deactivated job on its own; `apply_profile()`/`enable()` explicitly set `active = true` after scheduling, for exactly this reason.

None of this is meant to be copied verbatim into the new docs (that would read as an implementation post-mortem, not user-facing documentation) — it's here so you don't accidentally document the *original* design instead of the *corrected, shipped* one. The docs should read as if this is simply how pgfr v2 works, stated plainly and confidently, the same way the code comments do.

---

## 4. Invariants that need to come through clearly

These are pgfr's actual value proposition and should be prominent, especially in the top-level `README.md` and `pgfr_record/README.md` (they are effectively the pitch):

- **Append-only, everywhere.** No `UPDATE`, no `DELETE`, anywhere in `pgfr_record`. Retention is partition drop, never a `DELETE` statement.
- **The record/analyze boundary and the agent test.** Everything with a single correct answer lives in `pgfr_record` (what was captured, its shape, what kind of quantity each column is, how identity resolves over time). Everything requiring a threshold or opinion lives in `pgfr_analyze` (not yet rebuilt for v2). The operational proof of this boundary is the agent test (`scripts/agent_test.sh`): dump `pgfr_record` alone, restore it into an empty database on a *different* PostgreSQL major, regenerate the presentation views offline from the payload dictionary with no live source views, and answer real troubleshooting questions using nothing but psql.
- **No adaptive safety mechanisms.** No circuit breaker, no load shedding. Static bounds (`lock_timeout`, `job_timeout`) and a capture ledger that records every miss with its reason. The claim is that bounded, recorded degradation beats adaptive shutdown for an instrument whose value peaks during incidents — and (per §3 above) this has empirical backing now, not just an argument on paper.
- **The manifest is the single design artifact.** Every archive table, presentation view, capture plan entry, and column classification is a generated, pure function of one table (`pgfr_record.manifest`) plus the live catalog. Re-running `install.sql` is the entire upgrade procedure, including after a PostgreSQL major version upgrade.
- **Record is sufficient; analyze is acceleration.** A record-only install (or a `pg_dump` of one) is fully self-contained and self-describing. `pgfr_analyze`, once it exists, will make conclusions faster; it will not be required to reach them.

---

## 5. The four documents

### 5.1 `REFERENCE.md` — do this first

This is the technical reference: every table, view, and function `pgfr_record` provides, what it means, and how to use it. Organize it around the actual object model as it exists today, built from what you read in step 2 above. At minimum it needs to cover, accurately:

- The manifest (`pgfr_record.manifest`) and the PG15 seed census — what's captured, at what cadence, with what retention, and why (Groups A through E from the pack's §3.2, as actually seeded in `03_seed_pg15.sql` — note the actual row counts and any places the implementation's seed differs in small ways from the pack's own summary arithmetic; verify by querying the live table rather than trusting either document).
- The payload dictionary (`payload_schemas`) and why payloads are positional jsonb arrays, not objects — the storage-efficiency rationale, and the mint-together invariant.
- Archive tables: the uniform shape, what each of the six columns means, and how partitioning/retention works.
- Presentation views (`v_<name>`) — what they are, the multi-schema-variant UNION mechanism for mid-major column changes, and their version-current-only guarantee.
- `column_classes` — the counter/odometer/gauge/label/key taxonomy, and how it's derived (generator, not hand seed).
- The capture plan and the collector (`run_tier()`) — single-stamp semantics, debounce/anchor behavior, per-target failure isolation, and the corrected timeout model from §3 above.
- The capture ledger (`ledger_runs`, `ledger_captures`) — what outcomes mean and how to query "when was the recorder blind."
- Definitional helpers: `state_as_of()`, `resolve_relation()`/`resolve_index()`, `deltas()` — what each does, their exact calling convention (note that `state_as_of()` and `deltas()` return `SETOF record` and require a column-definition list from the caller; show a real, working example of each, copied from a test file and verified against a live install, not invented).
- Profiles, `apply_profile()`, `enable()`, `disable()`.
- `health_check()` — what it reports, and the explicit "this is genuinely read-only" callout from §3 above.
- `pgfr_analyze` — one honest paragraph: not yet rebuilt for v2, schema exists as a placeholder, see the project's milestone tracking for status.

### 5.2 `pgfr_record/README.md`

The extension-level README: what it is, how to install it (the three channels this repo actually supports — check `scripts/build_install_bundle.sh` and `scripts/build_dbdev_package.sh` for what those install paths actually look like from a user's perspective, and `test.sh`'s own comments for the channel names), a quick start (`enable()`, then `health_check()`), and the design highlights from §4 above. This is the file most likely to be read by someone deciding whether to install pgfr_record at all — lead with the pitch, not the schema.

### 5.3 `README.md` (top level)

The project overview: what pg_flight_recorder is, the two-extension structure (`pgfr_record` required/core, `pgfr_analyze` optional/not yet rebuilt for v2), supported PostgreSQL versions (15 through 18, per the pack's stated targets), and pointers into the two extensions' own READMEs and into `REFERENCE.md`. This is the front door; keep it short and let the other documents carry the depth.

### 5.4 `STATISTICS.md` — review and update, not necessarily a rewrite from zero

This file's original purpose (documenting, column by column, what statistics are collected and why) is now substantially covered by two things that didn't exist when it was written: the manifest census itself (a structured, queryable table of exactly this information) and the generated `COMMENT ON` system (milestone 4), which makes `\d+` on any presentation view self-documenting per column. Your job here is to figure out, and decide with the user if it's not obvious, whether `STATISTICS.md` should:

- become a thinner document that points readers at the manifest and at `\d+` rather than duplicating column-level detail that's now generated and could drift from a hand-maintained doc, or
- remain a detailed companion document, rewritten to describe the v2 manifest-driven census and column-class taxonomy in the same spirit as before.

Whichever direction, its content must actually match the v2 census (`03_seed_pg15.sql`) and taxonomy (`09_column_classes.sql`), not v1's fixed schema. Do not treat "for good measure" as license to skip this one; it just means use your judgment about scope rather than assuming a full rewrite is the right shape.

---

## 6. Conventions (do not skip this section)

- **No em dashes, anywhere** — prose, headings, code comments if you touch any, commit messages. Use a comma, colon, parentheses, or a separate sentence instead. This is a standing global instruction from the user across all projects; it was not consistently followed during the v2 implementation work (SQL comments and commit messages on this branch contain real em dashes), which is a known, acknowledged gap in the existing branch history, not a pattern to continue. Get this right in the new documentation and in any commits you make.
- **Markdown linting rules** (from this repo's own `CLAUDE.md`, project-checked-in instructions): blank lines before and after every list, heading, and fenced code block; dashes (`-`) not asterisks (`*`) for unordered lists; 2-space indentation for nested list items.
- **Conventional Commits / Conventional Branches**, per both the user's global `CLAUDE.md` and this repo's own: you're staying on `feat/pgfr-v2` (no new branch needed for this work), and each commit should be a conventional `docs:` commit.
- **Default to action.** Per the user's global instructions, write the actual rewritten files; don't produce a plan document or ask clarifying questions unless something is genuinely ambiguous after reading the code (the `STATISTICS.md` scope question in §5.4 is a legitimate example of something worth surfacing to the user rather than guessing).
- **Verify, don't assume.** This whole v2 implementation was built on a discipline of testing claims against a live PostgreSQL instance rather than trusting the design on paper (see §3's whole list of things that turned out to work differently than initially believed). Apply the same discipline here: before documenting that a function behaves a certain way or a query returns a certain shape, run it.

---

## 7. How to use this document

If you are the human reading this: open a new Claude Code session in this repository, on the `feat/pgfr-v2` branch, and give it this file's path with an instruction to read it fully and then proceed with the task in the order specified. It should not need anything else to get started.
