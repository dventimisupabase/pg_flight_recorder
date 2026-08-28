-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- pg_flight_recorder: pgfr_analyze module install script (v2)
--
-- pgfr_analyze reads pgfr_record's captured data, column classes, and
-- definitional helpers to answer questions requiring a threshold, baseline,
-- or opinion (pgfr-v2-context-pack.md §1, invariant 5); it never writes to
-- pgfr_record's schema. Requires pgfr_record installed first.
--
-- Uses psql `\ir` (include-relative); paths resolve against this file's
-- directory, so the script works from any working directory.
--
-- Files:
--   01_schema.sql   schema, config table, _get_config()

\ir sql/01_schema.sql
