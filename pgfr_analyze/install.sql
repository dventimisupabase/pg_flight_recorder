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
--   10_self_overhead.sql      self_overhead()
--   11_preflight.sql          preflight_check(), preflight_check_with_summary()
--   12_check_alerts.sql       check_alerts()
--   13_quarterly_review.sql   quarterly_review(), quarterly_review_with_summary()
--   14_table_hotspots.sql     table_hotspots()
--   15_index_analysis.sql     unused_indexes(), index_efficiency()
--   16_activity_readers.sql   vacuum_progress(), wal_archiver_status(), long_running_transactions()
--   17_performance_report.sql performance_report()
--   18_summary_report.sql     summary_report()
--   19_report.sql             report()

\ir sql/01_schema.sql
\ir sql/02_coverage.sql
\ir sql/03_config_tracking.sql
\ir sql/04_helpers.sql
\ir sql/05_query_dict.sql
\ir sql/06_query_performance.sql
\ir sql/07_xmin_horizon.sql
\ir sql/08_anomaly_detection.sql
\ir sql/09_capacity.sql
\ir sql/10_self_overhead.sql
\ir sql/11_preflight.sql
\ir sql/12_check_alerts.sql
\ir sql/13_quarterly_review.sql
\ir sql/14_table_hotspots.sql
\ir sql/15_index_analysis.sql
\ir sql/16_activity_readers.sql
\ir sql/17_performance_report.sql
\ir sql/18_summary_report.sql
\ir sql/19_report.sql
