#!/bin/bash
set -e

# Test runner for pgfr_record / pgfr_analyze.
#
# Usage:
#   ./test.sh [VERSION] [--channel=CHANNEL]
#
#   VERSION:  15 | 16 | 17 | 18 | all (default: all, runs in parallel)
#   CHANNEL:  psql | bundle | dbdev | all (default: all, runs sequentially per version)
#
# Channels exercise the three install paths the project ships:
#   psql    pgfr_record/install.sql via `psql -f` (\ir metacommand path)
#   bundle  scripts/build_install_bundle.sh output (Supabase SQL-editor flow)
#   dbdev   scripts/build_dbdev_package.sh output (dbdev / CREATE EXTENSION flow)
#
# When CHANNEL=all (default), each version installs each channel in sequence
# inside the same container, dropping schemas + unscheduling pgfr cron jobs
# between channels.
#
# Examples:
#   ./test.sh                              # all versions x all channels
#   ./test.sh 17                           # PG 17 only, all channels
#   ./test.sh 17 --channel=psql            # PG 17, psql channel only
#   ./test.sh --channel=bundle             # all versions, bundle channel only

COMPOSE_FILES="-f docker-compose.yml -f pgfr_record/docker-compose.yml -f pgfr_analyze/docker-compose.yml"

if command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose $COMPOSE_FILES"
elif docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose $COMPOSE_FILES"
else
    echo "Error: Neither 'docker-compose' nor 'docker compose' found"
    exit 1
fi

VERSION="all"
CHANNEL="all"

for arg in "$@"; do
    case "$arg" in
        --channel=*)
            CHANNEL="${arg#--channel=}"
            ;;
        15|16|17|18|all)
            VERSION="$arg"
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: ./test.sh [15|16|17|18|all] [--channel=psql|bundle|dbdev|all]"
            exit 1
            ;;
    esac
done

case "$CHANNEL" in
    psql|bundle|dbdev|all) ;;
    *)
        echo "Unknown channel: $CHANNEL"
        echo "Valid channels: psql, bundle, dbdev, all"
        exit 1
        ;;
esac

# Resolve the selected channel into the list of channels to run, in order.
if [ "$CHANNEL" = "all" ]; then
    CHANNELS=(psql bundle dbdev)
else
    CHANNELS=("$CHANNEL")
fi

# Build progress mode: quiet locally, plain on CI (see issue #44).
if [ -n "${CI:-}" ]; then
    BUILD_PROGRESS="--progress=plain"
else
    BUILD_PROGRESS="--quiet"
fi

# ----------------------------------------------------------------------------
# Channel-specific install helpers
#
# Each helper installs both pgfr_record and pgfr_analyze through the channel,
# then deactivates every pgfr_ cron job. Channel-specific transactional
# wrapping differs:
#   psql/dbdev   server-side install scripts have no BEGIN/COMMIT of their own,
#                so we use psql --single-transaction.
#   bundle       the bundle wraps itself in BEGIN; ... COMMIT; (the entry point
#                for users pasting into a SQL editor), so we omit
#                --single-transaction to avoid nesting.
# ----------------------------------------------------------------------------

deactivate_pgfr_cron() {
    local profile="$1"
    local service="$2"
    # Deactivate every pgfr_ cron job immediately before pg_cron's scheduler
    # has a chance to fire one. Closes the race documented in #46
    # (pgfr-sample-ring populating query_map_all before disable() runs,
    # making test_ring_buffer.sql's "empty initially" assertion flake).
    # Covers legacy AND v2 jobs by prefix, bypassing disable() (which would
    # unschedule the rows and break test_wiring.sql).
    $DOCKER_COMPOSE --profile "$profile" exec -T "$service" \
        psql -U postgres -d postgres \
        -c "UPDATE cron.job SET active = false WHERE jobname LIKE 'pgfr%'" \
        > /dev/null
}

install_psql() {
    local profile="$1"
    local service="$2"
    $DOCKER_COMPOSE --profile "$profile" exec -T "$service" \
        psql -U postgres -d postgres --single-transaction \
        -f /pgfr_record/install.sql > /dev/null
    deactivate_pgfr_cron "$profile" "$service"
    $DOCKER_COMPOSE --profile "$profile" exec -T "$service" \
        psql -U postgres -d postgres --single-transaction \
        -f /pgfr_analyze/install.sql > /dev/null
}

install_bundle() {
    local profile="$1"
    local service="$2"
    local tmpdir
    tmpdir=$(mktemp -d)
    ./scripts/build_install_bundle.sh pgfr_record  "$tmpdir/record.sql"  > /dev/null
    ./scripts/build_install_bundle.sh pgfr_analyze "$tmpdir/analyze.sql" > /dev/null
    # Bundle wraps itself in BEGIN/COMMIT — no --single-transaction.
    $DOCKER_COMPOSE --profile "$profile" exec -T "$service" \
        psql -U postgres -d postgres -f - < "$tmpdir/record.sql" > /dev/null
    deactivate_pgfr_cron "$profile" "$service"
    $DOCKER_COMPOSE --profile "$profile" exec -T "$service" \
        psql -U postgres -d postgres -f - < "$tmpdir/analyze.sql" > /dev/null
    rm -rf "$tmpdir"
}

install_dbdev() {
    local profile="$1"
    local service="$2"
    local tmpdir
    tmpdir=$(mktemp -d)
    ./scripts/build_dbdev_package.sh pgfr_record  "$tmpdir/record.sql"  > /dev/null
    ./scripts/build_dbdev_package.sh pgfr_analyze "$tmpdir/analyze.sql" > /dev/null
    $DOCKER_COMPOSE --profile "$profile" exec -T "$service" \
        psql -U postgres -d postgres --single-transaction \
        -f - < "$tmpdir/record.sql" > /dev/null
    deactivate_pgfr_cron "$profile" "$service"
    $DOCKER_COMPOSE --profile "$profile" exec -T "$service" \
        psql -U postgres -d postgres --single-transaction \
        -f - < "$tmpdir/analyze.sql" > /dev/null
    rm -rf "$tmpdir"
}

# Dispatch table: install <channel> <profile> <service>
install_channel() {
    case "$1" in
        psql)   install_psql   "$2" "$3" ;;
        bundle) install_bundle "$2" "$3" ;;
        dbdev)  install_dbdev  "$2" "$3" ;;
        *)
            echo "install_channel: unknown channel '$1'"
            exit 1
            ;;
    esac
}

# Reset all pgfr state between channels in a single container. Drops both
# schemas (CASCADE removes views/functions/tables) and unschedules every
# pgfr_ cron job so the next channel's install starts from a clean slate.
reset_pgfr_state() {
    local profile="$1"
    local service="$2"
    $DOCKER_COMPOSE --profile "$profile" exec -T "$service" \
        psql -U postgres -d postgres -c "
        DO \$\$
        BEGIN
            BEGIN
                PERFORM cron.unschedule(jobname)
                FROM cron.job
                WHERE jobname LIKE 'pgfr%';
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
        END;
        \$\$;
        DROP SCHEMA IF EXISTS pgfr_analyze CASCADE;
        DROP SCHEMA IF EXISTS pgfr_record  CASCADE;
        " > /dev/null
}

# ----------------------------------------------------------------------------
# Single-version test runner
# ----------------------------------------------------------------------------

run_single_version() {
    local pg_version=$1
    local service="postgres${pg_version}"
    local profile="pg${pg_version}"

    echo ""
    echo "========================================="
    echo "Testing on PostgreSQL $pg_version"
    echo "Channels: ${CHANNELS[*]}"
    echo "========================================="

    $DOCKER_COMPOSE --profile $profile down -v 2>/dev/null || true

    echo "Building PostgreSQL $pg_version image with pg_cron..."
    $DOCKER_COMPOSE --profile $profile build $BUILD_PROGRESS

    echo "Starting PostgreSQL $pg_version..."
    $DOCKER_COMPOSE --profile $profile up -d

    echo "Waiting for PostgreSQL to be ready..."
    # Use psql `SELECT 1` rather than pg_isready: pg_isready returns 0 for the
    # postgres image's init-phase temporary postmaster, but that server is torn
    # down before the real one starts, breaking subsequent calls. A successful
    # SELECT is a stronger readiness signal.
    ready=0
    for _ in {1..30}; do
        if $DOCKER_COMPOSE --profile $profile exec -T $service \
             psql -U postgres -tAc 'SELECT 1' > /dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 1
    done
    if [ "$ready" -ne 1 ]; then
        echo "ERROR: PostgreSQL $pg_version did not become ready within 30s."
        echo "----- Container logs (last 100 lines) -----"
        $DOCKER_COMPOSE --profile $profile logs --tail=100 $service 2>&1 || true
        echo "-------------------------------------------"
        exit 1
    fi

    echo "Installing prerequisite extensions (pg_cron, pg_stat_statements, pgtap)..."
    $DOCKER_COMPOSE --profile $profile exec -T $service \
        psql -U postgres -d postgres -c "
            CREATE EXTENSION IF NOT EXISTS pg_cron;
            CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
            CREATE EXTENSION IF NOT EXISTS pgtap;
        " > /dev/null

    local first=1
    for channel in "${CHANNELS[@]}"; do
        if [ "$first" -ne 1 ]; then
            echo ""
            echo "--- Resetting state before next channel ---"
            reset_pgfr_state "$profile" "$service"
        fi
        first=0

        echo ""
        echo "--- Channel: $channel ---"
        echo "Installing pgfr_record + pgfr_analyze via $channel..."
        install_channel "$channel" "$profile" "$service"

        echo "Running pgTAP suite (channel=$channel)..."
        $DOCKER_COMPOSE --profile $profile exec -T $service sh -c \
            'pg_prove --timer -j 1 -U postgres -d postgres /tests/record/*.sql /tests/analyze/*.sql'

        echo "PostgreSQL $pg_version channel=$channel: PASS"
    done

    echo ""
    echo "PostgreSQL $pg_version: PASS (channels: ${CHANNELS[*]})"

    $DOCKER_COMPOSE --profile $profile down -v
}

# ----------------------------------------------------------------------------
# Parallel-across-versions runner (channels still sequential within a version)
# ----------------------------------------------------------------------------

run_all_parallel() {
    echo ""
    echo "========================================="
    echo "Running parallel tests on PG 15, 16, 17, 18"
    echo "Channels per version: ${CHANNELS[*]}"
    echo "========================================="

    $DOCKER_COMPOSE --profile all down -v 2>/dev/null || true

    echo "Building PostgreSQL images with pg_cron..."
    $DOCKER_COMPOSE --profile all build $BUILD_PROGRESS --parallel

    echo "Starting all PostgreSQL instances..."
    $DOCKER_COMPOSE --profile all up -d

    echo "Waiting for all PostgreSQL instances to be ready..."
    for service in postgres15 postgres16 postgres17 postgres18; do
        ready=0
        for _ in {1..30}; do
            if $DOCKER_COMPOSE --profile all exec -T $service \
                 psql -U postgres -tAc 'SELECT 1' > /dev/null 2>&1; then
                ready=1
                break
            fi
            sleep 1
        done
        if [ "$ready" -ne 1 ]; then
            echo "ERROR: $service did not become ready within 30s."
            echo "----- Container logs (last 100 lines) -----"
            $DOCKER_COMPOSE --profile all logs --tail=100 $service 2>&1 || true
            echo "-------------------------------------------"
            exit 1
        fi
    done

    echo "Installing prerequisite extensions on all instances..."
    for service in postgres15 postgres16 postgres17 postgres18; do
        $DOCKER_COMPOSE --profile all exec -T $service \
            psql -U postgres -d postgres -c "
                CREATE EXTENSION IF NOT EXISTS pg_cron;
                CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
                CREATE EXTENSION IF NOT EXISTS pgtap;
            " > /dev/null
    done

    PIDS=()
    RESULTS_DIR=$(mktemp -d)

    for service in postgres15 postgres16 postgres17 postgres18; do
        version="${service#postgres}"
        (
            log="$RESULTS_DIR/$version.log"
            status_file="$RESULTS_DIR/$version.status"
            echo "=========================================" > "$log"
            echo "PostgreSQL $version (channels: ${CHANNELS[*]})" >> "$log"
            echo "=========================================" >> "$log"

            local first=1
            local overall_ok=1
            for channel in "${CHANNELS[@]}"; do
                if [ "$first" -ne 1 ]; then
                    reset_pgfr_state all "$service" >> "$log" 2>&1
                fi
                first=0

                echo "" >> "$log"
                echo "--- Channel: $channel ---" >> "$log"
                if ! install_channel "$channel" all "$service" >> "$log" 2>&1; then
                    overall_ok=0
                    break
                fi

                if ! $DOCKER_COMPOSE --profile all exec -T "$service" sh -c \
                    'pg_prove --timer -j 1 -U postgres -d postgres /tests/record/*.sql /tests/analyze/*.sql' \
                    >> "$log" 2>&1; then
                    overall_ok=0
                    break
                fi
            done

            if [ "$overall_ok" -eq 1 ]; then
                echo "PASS" > "$status_file"
            else
                echo "FAIL" > "$status_file"
            fi
        ) &
        PIDS+=($!)
    done

    FAILED=0
    for pid in "${PIDS[@]}"; do
        wait $pid || FAILED=1
    done

    for version in 15 16 17 18; do
        cat "$RESULTS_DIR/$version.log"
        echo ""
        STATUS=$(cat "$RESULTS_DIR/$version.status")
        if [ "$STATUS" = "FAIL" ]; then
            echo "PostgreSQL $version: FAIL"
            FAILED=1
        else
            echo "PostgreSQL $version: PASS (channels: ${CHANNELS[*]})"
        fi
        echo ""
    done

    rm -rf "$RESULTS_DIR"
    $DOCKER_COMPOSE --profile all down -v

    if [ $FAILED -eq 1 ]; then
        echo "========================================="
        echo "Some tests failed!"
        echo "========================================="
        exit 1
    fi

    echo "========================================="
    echo "All parallel tests passed!"
    echo "========================================="
}

if [ "$VERSION" = "all" ]; then
    run_all_parallel
elif [ "$VERSION" = "15" ] || [ "$VERSION" = "16" ] || [ "$VERSION" = "17" ] || [ "$VERSION" = "18" ]; then
    run_single_version "$VERSION"
else
    echo "Usage: ./test.sh [15|16|17|18|all] [--channel=psql|bundle|dbdev|all]"
    exit 1
fi
