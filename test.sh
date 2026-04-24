#!/bin/bash
set -e

# Test runner for pgfr_record
# Usage: ./test.sh [version]
#   version: 15, 16, 17, 18 (runs single version)
#   no args: runs all versions in parallel (default)
#
# Examples:
#   ./test.sh           # Test on PostgreSQL 15, 16, 17, 18 in parallel
#   ./test.sh 16        # Test on PostgreSQL 16 only

# Compose files: base + per-extension volumes
COMPOSE_FILES="-f docker-compose.yml -f pgfr_record/docker-compose.yml -f pgfr_analyze/docker-compose.yml"

# Detect docker compose command (standalone vs plugin)
if command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose $COMPOSE_FILES"
elif docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose $COMPOSE_FILES"
else
    echo "Error: Neither 'docker-compose' nor 'docker compose' found"
    exit 1
fi

VERSION="${1:-all}"

# Build progress mode: quiet locally (clean UX), plain on CI (full stdout/stderr
# visible so failures can be diagnosed without reruns). See issue #44.
if [ -n "${CI:-}" ]; then
    BUILD_PROGRESS="--progress=plain"
else
    BUILD_PROGRESS="--quiet"
fi

run_single_version() {
    local pg_version=$1
    local service="postgres${pg_version}"
    local profile="pg${pg_version}"

    echo ""
    echo "========================================="
    echo "Testing on PostgreSQL $pg_version"
    echo "========================================="

    # Clean up any existing containers
    $DOCKER_COMPOSE --profile $profile down -v 2>/dev/null || true

    # Build and start
    echo "Building PostgreSQL $pg_version image with pg_cron..."
    $DOCKER_COMPOSE --profile $profile build $BUILD_PROGRESS

    echo "Starting PostgreSQL $pg_version..."
    $DOCKER_COMPOSE --profile $profile up -d

    echo "Waiting for PostgreSQL to be ready..."
    # Use `psql -c 'SELECT 1'` rather than `pg_isready`: the latter returns 0
    # for the official postgres image's temporary init-phase postmaster, but
    # that server is torn down (socket disappears) before the real one is
    # started, and subsequent psql calls fail with "socket does not exist".
    # A successful SELECT is a stronger readiness signal.
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

    echo "Installing pg_cron and pg_stat_statements extensions..."
    $DOCKER_COMPOSE --profile $profile exec -T $service psql -U postgres -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_cron; CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" > /dev/null

    echo "Installing pgfr_record..."
    $DOCKER_COMPOSE --profile $profile exec -T $service psql -U postgres -d postgres --single-transaction -f /pgfr_record/install.sql > /dev/null

    echo "Installing reporting functions..."
    $DOCKER_COMPOSE --profile $profile exec -T $service psql -U postgres -d postgres --single-transaction -f /pgfr_analyze/install.sql > /dev/null

    echo "Installing pgTAP extension..."
    $DOCKER_COMPOSE --profile $profile exec -T $service psql -U postgres -d postgres -c "CREATE EXTENSION IF NOT EXISTS pgtap;" > /dev/null

    echo "Disabling scheduled jobs for testing..."
    $DOCKER_COMPOSE --profile $profile exec -T $service psql -U postgres -d postgres -c "SELECT pgfr_record.disable();" > /dev/null

    echo "Running tests with per-file timing..."
    $DOCKER_COMPOSE --profile $profile exec -T $service sh -c 'pg_prove --timer -U postgres -d postgres /tests/record/*.sql /tests/analyze/*.sql'

    echo "PostgreSQL $pg_version: PASS"

    # Clean up
    $DOCKER_COMPOSE --profile $profile down -v
}

run_all_parallel() {
    echo ""
    echo "========================================="
    echo "Running parallel tests on PG 15, 16, 17, 18"
    echo "========================================="

    # Clean up any existing containers
    $DOCKER_COMPOSE --profile all down -v 2>/dev/null || true

    # Build all images in parallel
    echo "Building PostgreSQL images with pg_cron..."
    $DOCKER_COMPOSE --profile all build $BUILD_PROGRESS --parallel

    # Start all PostgreSQL instances
    echo "Starting all PostgreSQL instances..."
    $DOCKER_COMPOSE --profile all up -d

    # Wait for all instances to be ready
    echo "Waiting for all PostgreSQL instances to be ready..."
    # See note in run_single_version: SELECT 1 is a stronger readiness
    # signal than pg_isready during the postgres image's init-phase restart.
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

    # Setup all instances in parallel
    echo "Setting up extensions on all instances..."
    for service in postgres15 postgres16 postgres17 postgres18; do
        (
            $DOCKER_COMPOSE --profile all exec -T $service psql -U postgres -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_cron; CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" > /dev/null
            $DOCKER_COMPOSE --profile all exec -T $service psql -U postgres -d postgres --single-transaction -f /pgfr_record/install.sql > /dev/null
            $DOCKER_COMPOSE --profile all exec -T $service psql -U postgres -d postgres --single-transaction -f /pgfr_analyze/install.sql > /dev/null
            $DOCKER_COMPOSE --profile all exec -T $service psql -U postgres -d postgres -c "CREATE EXTENSION IF NOT EXISTS pgtap;" > /dev/null
            $DOCKER_COMPOSE --profile all exec -T $service psql -U postgres -d postgres -c "SELECT pgfr_record.disable();" > /dev/null
        ) &
    done
    wait

    # Run tests in parallel, capturing output
    echo "Running tests in parallel..."
    echo ""

    PIDS=()
    RESULTS_DIR=$(mktemp -d)

    for service in postgres15 postgres16 postgres17 postgres18; do
        version="${service#postgres}"
        (
            echo "=========================================" > "$RESULTS_DIR/$version.log"
            echo "PostgreSQL $version" >> "$RESULTS_DIR/$version.log"
            echo "=========================================" >> "$RESULTS_DIR/$version.log"
            if $DOCKER_COMPOSE --profile all exec -T $service sh -c 'pg_prove --timer -U postgres -d postgres /tests/record/*.sql /tests/analyze/*.sql' >> "$RESULTS_DIR/$version.log" 2>&1; then
                echo "PASS" > "$RESULTS_DIR/$version.status"
            else
                echo "FAIL" > "$RESULTS_DIR/$version.status"
            fi
        ) &
        PIDS+=($!)
    done

    # Wait for all tests to complete
    FAILED=0
    for pid in "${PIDS[@]}"; do
        wait $pid || FAILED=1
    done

    # Display results
    for version in 15 16 17 18; do
        cat "$RESULTS_DIR/$version.log"
        echo ""
        STATUS=$(cat "$RESULTS_DIR/$version.status")
        if [ "$STATUS" = "FAIL" ]; then
            echo "PostgreSQL $version: FAIL"
            FAILED=1
        else
            echo "PostgreSQL $version: PASS"
        fi
        echo ""
    done

    rm -rf "$RESULTS_DIR"

    # Clean up
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
    run_single_version $VERSION
else
    echo "Usage: ./test.sh [version]"
    echo "  version: 15, 16, 17, 18 (single version) or omit for all versions in parallel"
    exit 1
fi
