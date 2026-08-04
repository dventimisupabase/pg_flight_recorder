-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- pg_flight_recorder: pgfr_analyze module install script
--
-- Requires pgfr_record module installed first.
-- Uses psql `\ir` (include-relative); paths resolve against this file's
-- directory, so the script works from any working directory.
--
-- Files:
--   01_core_metrics.sql           schema, modification_rate, hot_update_ratio,
--                                 anomaly_report, summary_report, compare,
--                                 xmin_horizon_history, current_xmin_horizon_holder
--   02_ring_readers.sql           recent_waits_current, recent_activity_current,
--                                 recent_locks_current, wait_summary, statement_compare
--   03_activity_storms_regressions.sql  activity_at, detect_query_storms,
--                                 _diagnose_regression_causes, detect_regressions
--   04_reports.sql                performance_report, check_alerts, report (overloads)
--   05_capacity.sql               preflight_check, quarterly_review,
--                                 capacity_summary, capacity_report
--   06_table_analysis.sql         table_compare, table_hotspots
--   07_index_analysis.sql         unused_indexes, index_efficiency
--   08_config.sql                 config_changes, config_at, config_health_check,
--                                 db_role_config_* functions
--   09_incident_analysis.sql      what_happened_at, incident_timeline, blast_radius
--   10_v2_readers.sql             v2_time_range, statement/table/index_activity_v2,
--                                 ring v2 reader rewrites
--   11_consumption_trends.sql     consumption_metric_series, consumption_trends,
--                                 _refresh_consumption_trends
--   12_consumption_weekly_trends.sql consumption_weekly_metric_series,
--                                 _refresh_consumption_trends_weekly (90d window)
--   13_column_semantics.sql       column_semantics registry (Issue #99)
--   14_coverage.sql               coverage, coverage_gaps (Issue #100)

\ir sql/01_core_metrics.sql
\ir sql/02_ring_readers.sql
\ir sql/03_activity_storms_regressions.sql
\ir sql/04_reports.sql
\ir sql/05_capacity.sql
\ir sql/06_table_analysis.sql
\ir sql/07_index_analysis.sql
\ir sql/08_config.sql
\ir sql/09_incident_analysis.sql
\ir sql/10_v2_readers.sql
\ir sql/11_consumption_trends.sql
\ir sql/12_consumption_weekly_trends.sql
\ir sql/13_column_semantics.sql
\ir sql/14_coverage.sql
