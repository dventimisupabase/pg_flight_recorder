#!/usr/bin/env bash
# setup_pg.sh — Install PostgreSQL 17, pg_flight_recorder, run pgbench for 1h+
# Security: localhost only, password auth, log_connections=on
# Run as root on Ubuntu 24.04

set -euo pipefail
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

PGVER=17
PGCLUSTER="bench"
PGPORT=5433
PGDB="pgfr_bench17"
PGFR_BRANCH="storage-overhaul-spec"
PGFR_DIR="/root/pgfr"

# Derive benchmark password from env var (never hardcode)
PGFR_BENCH_PW="${PGFR_BENCH_PW:-$(openssl rand -hex 16)}"

# ── 1. Install PostgreSQL 17 ─────────────────────────────────────────────────
log "Installing PostgreSQL $PGVER..."
apt-get update -qq
install -d /usr/share/postgresql-common/pgdg
curl -qso /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
  https://www.postgresql.org/media/keys/ACCC4CF8.asc
sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
  https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list'
apt-get update -qq
apt-get install -y \
  postgresql-${PGVER} \
  postgresql-${PGVER}-cron \
  postgresql-contrib-${PGVER} \
  git 2>&1 | tail -5
log "PostgreSQL $PGVER installed"

# ── 2. Create cluster ────────────────────────────────────────────────────────
log "Creating PG$PGVER cluster '$PGCLUSTER' on port $PGPORT..."
if pg_ctlcluster $PGVER $PGCLUSTER status &>/dev/null; then
  log "Cluster already exists"
else
  pg_createcluster --start $PGVER $PGCLUSTER --port $PGPORT -- --data-checksums
fi

# ── 3. Configure PostgreSQL (security + pg_cron) ────────────────────────────
log "Configuring PostgreSQL..."
PG_CONF="/etc/postgresql/$PGVER/$PGCLUSTER/postgresql.conf"
PG_HBA="/etc/postgresql/$PGVER/$PGCLUSTER/pg_hba.conf"

# Append required settings (idempotent: only if not already present)
if ! grep -q 'pgfr bench configuration' "$PG_CONF" 2>/dev/null; then
  cat >> "$PG_CONF" << 'EOF'

# pgfr bench configuration
listen_addresses = 'localhost'
log_connections = on
shared_preload_libraries = 'pg_cron,pg_stat_statements'
pg_stat_statements.max = 5000
pg_stat_statements.track = all
cron.database_name = 'pgfr_bench17'
shared_buffers = '1GB'
max_connections = 200
autovacuum = on
autovacuum_vacuum_cost_delay = '2ms'
EOF
fi

# pg_hba: password auth everywhere (no trust), peer for OS postgres user only
cat > "$PG_HBA" << 'EOF'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# OS postgres user: peer auth (for local admin)
local   all             postgres                                peer
# All others: scram-sha-256 only
local   all             all                                     scram-sha-256
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
EOF

log "Restarting cluster to apply config..."
pg_ctlcluster $PGVER $PGCLUSTER restart

# ── 4. Create database, user, extensions ─────────────────────────────────────
log "Creating database $PGDB..."
sudo -u postgres psql -p $PGPORT << EOSQL
DO
\$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgfr_bench17') THEN
    CREATE ROLE pgfr_bench17 WITH LOGIN PASSWORD '$PGFR_BENCH_PW';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE $PGDB OWNER pgfr_bench17'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$PGDB') \gexec

\c $PGDB
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_cron;
GRANT ALL ON SCHEMA cron TO pgfr_bench17;
EOSQL

# ── 5. Clone pg_flight_recorder ─────────────────────────────────────────────
log "Cloning pg_flight_recorder ($PGFR_BRANCH branch)..."
if [[ -d "$PGFR_DIR" ]]; then
  cd "$PGFR_DIR" && git pull --rebase
else
  git clone --depth 1 --branch "$PGFR_BRANCH" \
    https://github.com/dventimisupabase/pg_flight_recorder "$PGFR_DIR"
fi

# ── 6. Apply PG17 compatibility patch ───────────────────────────────────────
# PG17 renamed pg_stat_statements.blk_read_time -> shared_blk_read_time
# and blk_write_time -> shared_blk_write_time. Create a compat view.
log "Patching install.sql for PG17 compatibility..."
python3 << 'PYEOF'
import re

with open('/root/pgfr/pgfr_record/install.sql', 'r') as f:
    content = f.read()

# Replace the FROM pg_stat_statements in the snapshot() function CTE
# with a reference to our compat view
old_from = '                    FROM pg_stat_statements s\n                    WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())'
new_from = '                    FROM pgfr_record.pg_stat_statements_compat s\n                    WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())'

if old_from in content:
    content = content.replace(old_from, new_from)
    print('Applied PG17 compat patch (FROM pg_stat_statements)')
else:
    print('Pattern not found - skipping patch (may already be patched)')

with open('/root/pgfr/pgfr_record/install.sql', 'w') as f:
    f.write(content)
PYEOF

# ── 7. Install pg_flight_recorder ───────────────────────────────────────────
log "Installing pg_flight_recorder..."
sudo -u postgres psql -p $PGPORT -d $PGDB -f "$PGFR_DIR/pgfr_record/install.sql"

# Create PG17 compatibility view (maps renamed columns)
sudo -u postgres psql -p $PGPORT -d $PGDB << 'EOSQL'
CREATE OR REPLACE VIEW pgfr_record.pg_stat_statements_compat AS
SELECT
    userid, dbid, toplevel, queryid, query, plans,
    total_plan_time, min_plan_time, max_plan_time, mean_plan_time, stddev_plan_time,
    calls, total_exec_time, min_exec_time, max_exec_time, mean_exec_time, stddev_exec_time,
    rows, shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written,
    local_blks_hit, local_blks_read, local_blks_dirtied, local_blks_written,
    temp_blks_read, temp_blks_written,
    shared_blk_read_time  AS blk_read_time,
    shared_blk_write_time AS blk_write_time,
    wal_records, wal_fpi, wal_bytes,
    jit_functions, jit_generation_time,
    jit_inlining_count, jit_inlining_time,
    jit_optimization_count, jit_optimization_time,
    jit_emission_count, jit_emission_time
FROM pg_stat_statements;
EOSQL
log "pg_stat_statements_compat view created"

# Disable pss conflict check (causes false positives under debug)
sudo -u postgres psql -p $PGPORT -d $PGDB \
  -c "INSERT INTO pgfr_record.config(key,value) VALUES('check_pss_conflicts','false')
      ON CONFLICT (key) DO UPDATE SET value='false';"

# ── 8. Setup pg_cron jobs (socket connections) ───────────────────────────────
log "Setting up pg_cron jobs..."
cat > /tmp/setup_cron.sql << 'SQLEOF'
SELECT cron.schedule('pgfr-snapshot', '* * * * *',
  'SET statement_timeout = ''10s''; SELECT pgfr_record.snapshot()')
WHERE NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-snapshot');

SELECT cron.schedule('pgfr-sample', '* * * * *',
  'SET statement_timeout = ''5s''; SELECT pgfr_record.sample()')
WHERE NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-sample');

SELECT cron.schedule('pgfr-flush', '*/5 * * * *',
  'SET statement_timeout = ''10s''; SELECT pgfr_record.flush_ring_to_aggregates()')
WHERE NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-flush');

SELECT cron.schedule('pgfr-archive', '*/15 * * * *',
  'SET statement_timeout = ''10s''; SELECT pgfr_record.archive_ring_samples()')
WHERE NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-archive');

SELECT cron.schedule('pgfr-cleanup', '0 3 * * *',
  'SET statement_timeout = ''60s''; SELECT pgfr_record.cleanup_aggregates()')
WHERE NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-cleanup');

-- Use unix socket (empty nodename) for pg_cron connections
UPDATE cron.job SET nodename = '';
SQLEOF
sudo -u postgres psql -p $PGPORT -d $PGDB -f /tmp/setup_cron.sql

# ── 9. Initialize pgbench and run workload ───────────────────────────────────
log "Initializing pgbench (scale factor 50 = 5M accounts)..."
sudo -u postgres pgbench -p $PGPORT -d $PGDB -i -s 50

log "Pre-filling pg_stat_statements with 5000 distinct queryids..."
python3 -c "
for i in range(1, 5001):
    print(f'SELECT {i} AS n;')
" > /tmp/fill_pgss.sql
sudo -u postgres psql -p $PGPORT -d $PGDB -f /tmp/fill_pgss.sql > /dev/null

PGSS_COUNT=$(sudo -u postgres psql -p $PGPORT -d $PGDB -tA \
  -c "SELECT count(*) FROM pg_stat_statements")
log "pg_stat_statements entries: $PGSS_COUNT"

# Run pgbench for 90 minutes (>= 1 hour as required by §9.2)
log "Running pgbench workload for 90 minutes (5400s)..."
# shellcheck disable=SC2024 # /tmp/pgbench.log is world-writable; redirect owner need not be postgres
sudo -u postgres pgbench -p $PGPORT -d $PGDB \
  -c 10 -j 2 -T 5400 > /tmp/pgbench.log 2>&1 &
PGBENCH_PID=$!
log "pgbench running (PID $PGBENCH_PID), waiting for data to accumulate..."
wait $PGBENCH_PID
log "pgbench complete"

# Run a few manual snapshots to ensure we have data
sudo -u postgres psql -p $PGPORT -d $PGDB \
  -c "SELECT pgfr_record.snapshot();" 2>&1

SNAP_COUNT=$(sudo -u postgres psql -p $PGPORT -d $PGDB -tA \
  -c "SELECT count(*) FROM pgfr_record.snapshots")
STMT_COUNT=$(sudo -u postgres psql -p $PGPORT -d $PGDB -tA \
  -c "SELECT count(*) FROM pgfr_record.statement_snapshots")
log "Setup complete: $SNAP_COUNT snapshots, $STMT_COUNT statement rows"
