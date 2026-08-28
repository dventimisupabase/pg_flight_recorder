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
--   01_schema.sql           schema, config table, _get_config()
--   02_coverage.sql         coverage(), coverage_gaps()
--   03_config_tracking.sql  config_changes(), config_at(), config_health_check()
--   04_helpers.sql          _deltas_col_defs()
--   05_query_dict.sql       query_dict, refresh_query_dict()
--   06_query_performance.sql  detect_regressions(), detect_query_storms()
--   07_xmin_horizon.sql       xmin_horizon_history(), current_xmin_horizon_holder()
--   08_anomaly_detection.sql  anomaly_report()
--   09_capacity.sql           capacity_summary()

\ir sql/01_schema.sql
\ir sql/02_coverage.sql
\ir sql/03_config_tracking.sql
\ir sql/04_helpers.sql
\ir sql/05_query_dict.sql
\ir sql/06_query_performance.sql
\ir sql/07_xmin_horizon.sql
\ir sql/08_anomaly_detection.sql
\ir sql/09_capacity.sql
