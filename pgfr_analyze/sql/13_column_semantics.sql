-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

--------------------------------------------------------------------------------
-- Machine-readable column-semantics registry (Issue #99).
--
-- Every user-facing column carries a structured semantic annotation, either as
-- a COMMENT ON COLUMN (views) or as a per-column line in the function comment
-- (set-returning functions, whose output columns have no pg_description slot).
-- The annotation grammar is:
--
--   [<class>] [<units>] [interval-mean|instantaneous]? <prose>
--
-- where <class> is one of the taxonomy classes defined in STATISTICS.md:
--
--   point-sample   Mode A ring-sample observation; estimates time-in-state,
--                  carries binomial error, never event counts
--   counter-delta  difference of a cumulative counter between two snapshots;
--                  exact over the interval, mean rate only
--   gauge          instantaneous level read at collection time; exact at that
--                  instant, undefined between ticks
--   derived        computed from the above (ratios, estimates, assessments);
--                  inherits its inputs' semantics
--   dimension      identity, label, or timestamp; not a measurement
--
-- For set-returning functions the function comment carries a block:
--
--   Output columns:
--     <column>: [<class>] [<units>] <prose>
--
-- column_semantics() parses both sources out of pg_description at call time,
-- so the registry cannot drift from the comments: the comment IS the registry
-- entry. Malformed or missing annotations simply do not appear here, and the
-- pgTAP suites (pgfr_record/tests/23_column_semantics.sql,
-- pgfr_analyze/tests/27_column_semantics.sql) fail when any exposed column is
-- absent from this registry.
--
-- Channel caveat: the dbdev package build strips every COMMENT ON statement
-- to fit dbdev's 250,000-character cap (scripts/build_dbdev_package.sh), so
-- on a dbdev-channel install this registry is empty. The psql and bundle
-- install channels carry the full annotations.
--------------------------------------------------------------------------------

create or replace function pgfr_analyze.column_semantics()
returns table (
    relation        text,
    column_name     text,
    semantic_class  text,
    units           text,
    interval_basis  text,
    notes           text
)
language sql
stable
as $$
with view_columns as (
    -- COMMENT ON COLUMN entries for every view in the two pgfr schemas
    select n.nspname || '.' || c.relname as relation,
           a.attname::text               as column_name,
           d.description
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
    join pg_description d
      on d.objoid = c.oid
     and d.classoid = 'pg_class'::regclass
     and d.objsubid = a.attnum
    where n.nspname in ('pgfr_record', 'pgfr_analyze')
      and c.relkind = 'v'
),
function_lines as (
    -- one line per output column from the 'Output columns:' block of each
    -- public set-returning function's comment
    select n.nspname || '.' || p.proname || '()' as relation,
           trim(line.txt)                        as line
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join pg_description d
      on d.objoid = p.oid
     and d.classoid = 'pg_proc'::regclass
    cross join lateral unnest(
        string_to_array(substring(d.description from 'Output columns:(.*)$'), E'\n')
    ) as line(txt)
    where n.nspname = 'pgfr_analyze'
      and p.proname not like '\_%'
      and p.proretset
      and d.description like '%Output columns:%'
),
function_columns as (
    select relation,
           (regexp_match(line, '^([a-z0-9_]+): (.*)$'))[1] as column_name,
           (regexp_match(line, '^([a-z0-9_]+): (.*)$'))[2] as description
    from function_lines
    where line ~ '^[a-z0-9_]+: '
),
annotated as (
    select relation, column_name, description from view_columns
    union all
    select relation, column_name, description from function_columns
)
select a.relation,
       a.column_name,
       m.parts[1] as semantic_class,
       m.parts[2] as units,
       m.parts[4] as interval_basis,
       m.parts[5] as notes
from annotated a
cross join lateral (
    select regexp_match(
        a.description,
        '^\[(point-sample|counter-delta|gauge|derived|dimension)\] \[([^\]]+)\]( \[(interval-mean|instantaneous)\])? (.+)$'
    ) as parts
) m
where m.parts is not null
$$;

comment on function pgfr_analyze.column_semantics() is
'Machine-readable registry of column-level statistical semantics for every user-facing pgfr column (see STATISTICS.md for the taxonomy). Parses the structured prefix of COMMENT ON COLUMN entries on pgfr_record/pgfr_analyze views and the "Output columns:" blocks of pgfr_analyze set-returning function comments, so the comments are the single source of truth and the registry cannot drift from them. Returns one row per annotated column.
Output columns:
  relation: [dimension] [text] Schema-qualified view name, or function name suffixed with () for set-returning function outputs.
  column_name: [dimension] [text] Column name within the relation.
  semantic_class: [dimension] [text] Taxonomy class from STATISTICS.md: point-sample, counter-delta, gauge, derived, or dimension.
  units: [dimension] [text] Units of measure as declared in the annotation (bytes, blocks/s, percent, count, text, ...).
  interval_basis: [dimension] [text] For rates and levels: interval-mean or instantaneous; NULL when not applicable.
  notes: [dimension] [text] Prose remainder of the annotation, including denominator disclosure for proportions.';


-- Renderer helper (Issue #102): unit and interval-basis string for a column,
-- sourced from the registry so report prose cannot drift from the schema
-- annotations. p_fallback covers the dbdev channel, where COMMENT ON is
-- stripped and the registry is empty (see the header caveat above).
create or replace function pgfr_analyze._interval_basis(
    p_relation text,
    p_column   text,
    p_fallback text
)
returns text
language sql
stable
as $$
    select coalesce(
        (select cs.units
                || case when cs.interval_basis is not null
                        then ', ' || cs.interval_basis else '' end
         from pgfr_analyze.column_semantics() cs
         where cs.relation = p_relation and cs.column_name = p_column
         limit 1),
        p_fallback)
$$;

comment on function pgfr_analyze._interval_basis(text, text, text) is
'Units and interval basis of a column as a display string (e.g. count/s, interval-mean), read from column_semantics() with a literal fallback for comment-stripped installs. Keeps report prose in sync with the registry.';
