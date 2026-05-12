-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Uninstall pgfr_analyze (reporting/analysis functions)
-- Run with: psql --single-transaction -f pgfr_analyze/uninstall.sql

DROP SCHEMA IF EXISTS pgfr_analyze CASCADE;
