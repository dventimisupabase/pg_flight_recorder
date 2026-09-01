-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Manifest: the single design artifact. One row per capture target. All
-- generator and collector behavior is a pure function of this table.
-- See pgfr-v2-context-pack.md §3.1.
CREATE TABLE IF NOT EXISTS pgfr_record.manifest (
  source_view     text PRIMARY KEY,
  min_major       int  NOT NULL DEFAULT 15,
  max_major       int,
  cadence_tier    text NOT NULL CHECK (cadence_tier IN ('fast','medium','slow','on_change')),
  natural_key     text[] NOT NULL DEFAULT '{}',
  keyless         boolean NOT NULL DEFAULT false,
  debounce        boolean NOT NULL DEFAULT false,
  compare_ignore  text[] NOT NULL DEFAULT '{}',
  anchor_every    interval,
  retention       interval NOT NULL,
  logged          boolean NOT NULL DEFAULT true,
  size_class      text NOT NULL CHECK (size_class IN ('singleton','per_db','per_relation','per_backend','per_slot')),
  requires        text,
  enabled         boolean NOT NULL DEFAULT true,
  notes           text,
  CHECK (debounce = false OR anchor_every IS NOT NULL),
  CHECK (keyless = false OR debounce = false)
);

COMMENT ON TABLE pgfr_record.manifest IS
    'The single design artifact of pgfr_record: one row per capture target (a stats view, system view, or catalog projection). Generator and collector behavior is a pure function of this table alone.';
COMMENT ON COLUMN pgfr_record.manifest.source_view IS 'Schema-qualified source view, e.g. pg_catalog.pg_stat_database, or a pgfr-defined projection view.';
COMMENT ON COLUMN pgfr_record.manifest.min_major IS 'Lowest PostgreSQL major version on which this source_view exists.';
COMMENT ON COLUMN pgfr_record.manifest.max_major IS 'Highest PostgreSQL major version on which this source_view exists; NULL means still present.';
COMMENT ON COLUMN pgfr_record.manifest.cadence_tier IS 'fast | medium | slow | on_change. Maps to a pg_cron job interval via the active profile.';
COMMENT ON COLUMN pgfr_record.manifest.natural_key IS 'Column names forming this target''s identity. Empty array means singleton (no key).';
COMMENT ON COLUMN pgfr_record.manifest.keyless IS 'True when the source has no stable row identity (e.g. pg_locks). Forces debounce = false.';
COMMENT ON COLUMN pgfr_record.manifest.debounce IS 'True to skip appending a row whose content is unchanged since its most recent capture, within the current anchor window.';
COMMENT ON COLUMN pgfr_record.manifest.compare_ignore IS 'Column names nulled out of the compare payload before row-hashing (estimator-churn columns etc.); the stored payload keeps every value intact.';
COMMENT ON COLUMN pgfr_record.manifest.anchor_every IS 'Interval between unconditional full captures of a debounced target. Required when debounce = true; aligns to partition width.';
COMMENT ON COLUMN pgfr_record.manifest.retention IS 'How long captured rows are kept. Implemented as partition drop, never DELETE.';
COMMENT ON COLUMN pgfr_record.manifest.logged IS 'False makes the archive table''s partitions UNLOGGED. Default true (logged).';
COMMENT ON COLUMN pgfr_record.manifest.size_class IS 'Coarse cardinality label (singleton | per_db | per_relation | per_backend | per_slot), used only by the cost model and docs.';
COMMENT ON COLUMN pgfr_record.manifest.requires IS 'Precondition for full visibility: an extension name, GUC setting, or role/privilege note.';
COMMENT ON COLUMN pgfr_record.manifest.enabled IS 'False rows are still listed (with notes) so "why doesn''t pgfr capture X" is queryable, but get no archive table or capture-plan entry.';
COMMENT ON COLUMN pgfr_record.manifest.notes IS 'Free-text design rationale for this row.';

-- Rollups (milestone 8): long-horizon, compressed history for targets
-- whose raw retention is too short to correlate against Group D's 365d
-- config-change history. Added via ALTER, not the CREATE TABLE above, per
-- the additive-only schema-evolution policy -- re-running install.sql is
-- the upgrade path for an already-installed manifest table.
ALTER TABLE pgfr_record.manifest
  ADD COLUMN IF NOT EXISTS rollup_retention   interval,
  ADD COLUMN IF NOT EXISTS rollup_granularity interval;

ALTER TABLE pgfr_record.manifest DROP CONSTRAINT IF EXISTS rollup_shape;
ALTER TABLE pgfr_record.manifest
  ADD CONSTRAINT rollup_shape
  CHECK (rollup_retention IS NULL
         OR (rollup_granularity IS NOT NULL AND rollup_granularity < retention));

COMMENT ON COLUMN pgfr_record.manifest.rollup_retention IS 'How long compressed rollup rows are kept, independent of retention (the raw window). NULL means this target has no rollup. Implemented as partition drop, same mechanism as retention.';
COMMENT ON COLUMN pgfr_record.manifest.rollup_granularity IS 'Bucket width for this target''s rollup (e.g. 1 day). Must be strictly less than retention: a bucket can only be closed by aggregating raw rows that are still guaranteed to exist.';

-- Column-class legend: the taxonomy pgfr_record stores and describes but
-- never judges with (that boundary is the agent test, §1 invariant 2).
-- Seeded in milestone 4, not here; the table exists now because
-- definitional helpers and presentation-view generation reference its
-- shape from the start.
CREATE TABLE IF NOT EXISTS pgfr_record.column_classes (
  source_view   text NOT NULL,
  column_name   text NOT NULL,
  class         text NOT NULL CHECK (class IN ('counter','odometer','gauge','label','key','dict')),
  reset_column  text,
  PRIMARY KEY (source_view, column_name)
);

COMMENT ON TABLE pgfr_record.column_classes IS
    'Legend mapping each source_view column to its class: counter (monotone, resettable), odometer (monotone, non-resettable, e.g. LSNs/XIDs), gauge (point-in-time), label (identity/dimension). Consumed by definitional helpers (deltas()) and by pgfr_analyze; owned only here.';
COMMENT ON COLUMN pgfr_record.column_classes.reset_column IS 'Name of the column (in the same source_view) whose advance signals a reset for this counter, when applicable.';

-- Rollup specs (milestone 8): hand-seeded, Group C (gauge) targets only.
-- A gauge's per-bucket rollup is a judgment call about which statistic
-- matters (unlike a counter's, which is mechanically "first/last value" --
-- see generate_rollups()), so this is a small override list in the same
-- spirit as column_classes' own override list: a documented starting
-- point, not a claim of exhaustive coverage.
--
-- Deliberately threshold-free (§ record/analyze boundary): value_expr and
-- agg compute a continuous quantity (a duration, a count of samples in a
-- structurally-defined state) with no hardcoded cutoff baked in here. A
-- cutoff like "longer than 5 minutes" is an opinion, and belongs to
-- pgfr_analyze reading a stored MAX at query time, not to pgfr_record
-- deciding it once at capture time.
CREATE TABLE IF NOT EXISTS pgfr_record.rollup_specs (
  source_view   text NOT NULL,
  stat_name     text NOT NULL,
  agg           text NOT NULL CHECK (agg IN ('count','sum','max','min')),
  value_expr    text NOT NULL,
  predicate_sql text,
  PRIMARY KEY (source_view, stat_name)
);

COMMENT ON TABLE pgfr_record.rollup_specs IS
    'Hand-seeded rollup statistics for Group C (gauge) targets: one row per (source_view, stat_name), aggregated across every key in a rollup bucket (not per-key -- Group C''s value is "did this happen in this bucket", not per-backend/per-slot history). Consumed by generate_rollups()/run_tier()''s bucket-close step. Group B (counter/odometer) targets need no entries here: their rollup is mechanical, derived directly from column_classes.';
COMMENT ON COLUMN pgfr_record.rollup_specs.agg IS 'How value_expr is aggregated across every row in the bucket: count | sum | max | min.';
COMMENT ON COLUMN pgfr_record.rollup_specs.value_expr IS 'A SQL expression over the target''s presentation view columns. Must evaluate to numeric (the rollup table''s value column is numeric) -- a duration needs extract(epoch FROM ...), not a bare interval subtraction. Must be a continuous quantity, never a pre-thresholded boolean -- see the comment above this table for why.';
COMMENT ON COLUMN pgfr_record.rollup_specs.predicate_sql IS 'Optional structural row filter (e.g. state = ''idle in transaction''). Identity/state equality only, never a duration or magnitude threshold -- that judgment belongs to pgfr_analyze at read time.';

-- Payload dictionary: the positional order of every jsonb-array payload
-- ever captured. Append-only — a changed view shape is a new row, never
-- an edit. Written only by the generator (mint-together invariant, §4.4);
-- read by the generator (presentation views) and by anyone reading raw
-- payloads.
CREATE TABLE IF NOT EXISTS pgfr_record.payload_schemas (
  schema_id   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_view text NOT NULL,
  columns     text[] NOT NULL,
  type_names  text[] NOT NULL,
  fingerprint text NOT NULL,
  first_seen  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_view, fingerprint)
);

COMMENT ON TABLE pgfr_record.payload_schemas IS
    'Dictionary of positional payload layouts: position i of an archive row''s payload array is columns[i+1]. Minted atomically with each target''s capture statement by the generator; never hand-edited.';
COMMENT ON COLUMN pgfr_record.payload_schemas.columns IS 'Column names in payload array position order.';
COMMENT ON COLUMN pgfr_record.payload_schemas.type_names IS 'Column type names in payload array position order; drives presentation-view cast generation.';
COMMENT ON COLUMN pgfr_record.payload_schemas.fingerprint IS 'Hash of (source_view, columns, type_names); a changed live view shape mints a new schema_id rather than mutating this row.';

-- The catalog identity dimension (Group D): resolves any relid/indexrelid
-- as of any captured_at, surviving OID reuse across DROP/CREATE.
-- relfrozenxid/relminmxid/reltuples were added after the initial v2
-- rewrite, additively (schema evolution policy: new columns appended at
-- the end, never reordered), so pgfr_analyze can track per-relation XID/
-- MultiXID wraparound distance over time without a second capture target.
CREATE OR REPLACE VIEW pgfr_record.src_catalog_identity AS
SELECT
    c.oid,
    c.relname,
    c.relnamespace,
    n.nspname,
    c.relkind,
    c.relispartition,
    c.relfrozenxid,
    c.relminmxid,
    c.reltuples
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace;

COMMENT ON VIEW pgfr_record.src_catalog_identity IS
    'Projection over pg_class join pg_namespace. Captured as a Group D (state-history) manifest target so relid/indexrelid can be resolved as of any past captured_at, surviving OID reuse across DROP/CREATE. Also carries relfrozenxid/relminmxid/reltuples for per-relation XID/MultiXID wraparound distance tracking.';
