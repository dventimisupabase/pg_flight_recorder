#!/usr/bin/env bash
# Build a self-contained single-file install bundle suitable for clients
# that do not process psql metacommands -- e.g. the Supabase dashboard
# SQL editor. Paste the resulting file in and run it.
#
# Differs from scripts/build_dbdev_package.sh:
#   - No minification. Comments, blank lines, and COMMENT ON statements
#     are preserved so a reader of the bundle can still navigate it.
#   - Inserts a section banner before each inlined fragment.
#   - Wraps the whole script in BEGIN/COMMIT so a partial failure rolls
#     back cleanly (mirrors `psql --single-transaction`).
#
# Usage:   scripts/build_install_bundle.sh <ext-dir> <out-file>
# Example: scripts/build_install_bundle.sh pgfr_record dist/pgfr_record-bundle.sql

set -euo pipefail

EXT_DIR="${1:?usage: $0 <ext-dir> <out-file>}"
OUT="${2:?usage: $0 <ext-dir> <out-file>}"
INSTALL="${EXT_DIR}/install.sql"

[ -f "$INSTALL" ] || { echo "build_install_bundle: missing $INSTALL" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"

cat > "$OUT" <<EOF
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia
-- Licensed under the Apache License, Version 2.0
-- https://www.apache.org/licenses/LICENSE-2.0
--
-- pg_flight_recorder install bundle for ${EXT_DIR}
--
-- Self-contained single-file install. Paste into the Supabase SQL editor
-- (or any client that does not process psql metacommands) and run.
-- Wrapped in BEGIN/COMMIT so a partial failure rolls back cleanly.

BEGIN;

EOF

awk -v ext_dir="$EXT_DIR" '
/^\\ir / {
    path = ext_dir "/" $2
    print ""
    print "-- =========================================================="
    print "-- " path
    print "-- =========================================================="
    while ((getline line < path) > 0) print line
    close(path)
    next
}
/^\\/ {
    printf "build_install_bundle: unhandled psql metacommand in %s: %s\n", FILENAME, $0 > "/dev/stderr"
    exit 2
}
{ print }
' "$INSTALL" >> "$OUT"

cat >> "$OUT" <<'EOF'

COMMIT;
EOF

SIZE=$(wc -c < "$OUT")
echo "Built $OUT (${SIZE} bytes)"
