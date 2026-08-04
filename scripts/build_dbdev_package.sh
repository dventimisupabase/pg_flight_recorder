#!/usr/bin/env bash
# Build a self-contained single-file extension SQL script suitable for dbdev
# publishing. dbdev enforces a 250,000-character file-size cap, so the output
# is additionally minified: full-line `--` comments and blank lines are
# stripped. Dollar-quoted bodies (function source, etc.) and inline quoted
# literals are preserved verbatim.
#
# Required because the modular install.sql files source sql/*.sql via psql
# `\i` meta-commands with Docker-volume absolute paths. CREATE EXTENSION runs
# the script server-side and does not evaluate psql meta-commands, and the
# Docker paths do not exist on end-user machines.
#
# Usage:   scripts/build_dbdev_package.sh <ext-dir> <out-file>
# Example: scripts/build_dbdev_package.sh pgfr_record pgfr_record/pgfr_record--0.0.0.sql
set -euo pipefail

EXT_DIR="${1:?usage: $0 <ext-dir> <out-file>}"
OUT="${2:?usage: $0 <ext-dir> <out-file>}"
INSTALL="${EXT_DIR}/install.sql"

[ -f "$INSTALL" ] || { echo "build_dbdev_package: missing $INSTALL" >&2; exit 1; }

# License header. Written to $OUT before awk runs so the minifier (which
# strips `--` lines from source files) doesn't drop it. Source files carry
# their own SPDX headers for source-form distribution; this banner ensures
# the bundled single-file dbdev package surfaces the license too.
cat > "$OUT" <<'LICENSE_EOF'
-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia
-- Licensed under the Apache License, Version 2.0
-- https://www.apache.org/licenses/LICENSE-2.0

LICENSE_EOF

awk -v ext_dir="$EXT_DIR" '
# Minifier stages:
#   1. Inline  : replace `\i <path>` with the referenced file contents.
#   2. Strip   : drop full-line `--` comments, blank lines, trailing
#                whitespace, and leading indentation. Applied to top-level
#                SQL and PL/pgSQL bodies alike.
#   3. Collapse: on lines containing no quote characters, collapse runs of
#                internal whitespace to a single space. String literals are
#                preserved verbatim.
#   4. COMMENT ON: drop whole `COMMENT ON ... ;` statements. These are pure
#                documentation (only visible in psql `\d+`) and their
#                removal costs ~28 KB for pgfr_record, which matters for
#                fitting under dbdev'"'"'s 250,000-character cap. The full
#                COMMENT ON statements remain in the source repo and
#                REFERENCE.md carries the same content.

function emit_line(line,   stripped) {
    stripped = line
    sub(/^[ \t]+/, "", stripped)
    sub(/[ \t]+$/, "", stripped)
    if (stripped == "") return
    if (stripped ~ /^--/) return
    # Track whether we are inside a multi-line COMMENT ON block so we can
    # also drop its continuation lines. A COMMENT ON statement ends at a
    # closing quote followed by the semicolon (…something.\x27;) — NOT at any
    # line that merely ends with ;. Comment prose can legitimately end a line
    # with a bare semicolon (e.g. an example invocation inside the text), and
    # treating that as the statement end used to spill the rest of the
    # comment string into the output as bogus SQL. The [^\x27] guard also
    # keeps an escaped quote (\x27\x27;) from reading as the terminator.
    if (in_comment_on) {
        if (stripped ~ /[^\x27]\x27[ \t]*;[ \t]*$/) in_comment_on = 0
        return
    }
    if (stripped ~ /^(COMMENT ON|comment on)[ \t]/) {
        if (stripped !~ /[^\x27]\x27[ \t]*;[ \t]*$/) in_comment_on = 1
        return
    }
    if (stripped !~ /[\x27"]|\$\$|\$[A-Za-z_]+\$/) {
        gsub(/[ \t]+/, " ", stripped)
    }
    print stripped
}

/^\\ir / {
    # `\ir <rel-path>` — resolve relative to the extension directory.
    path = ext_dir "/" $2
    while ((getline line < path) > 0) emit_line(line)
    close(path)
    next
}
{ emit_line($0) }
' "$INSTALL" >> "$OUT"

SIZE=$(wc -c < "$OUT")
echo "Built $OUT (${SIZE} bytes)"
