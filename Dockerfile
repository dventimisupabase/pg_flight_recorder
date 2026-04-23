ARG PG_VERSION=16
FROM postgres:${PG_VERSION}

# Pinned upstream versions (see issue #44 for rationale).
# Bump these when upgrading; unpinned `main` clones caused intermittent CI
# failures that were hard to reproduce or diagnose.
#
# pg_cron: pinned by SHA rather than by tag. The latest tag (v1.6.7) changes
# scheduler startup timing in a way that breaks the install → disable() race
# window our test harness depends on. Main HEAD at this SHA matches the
# behavior our existing tests were validated against.
ARG PG_CRON_SHA=61d693be59f456dbc2e26f73bf5e81e4fed7d73c
ARG PGTAP_REF=v1.3.4

# Install build dependencies, pg_cron, and pgTAP
RUN apt-get update \
    && apt-get install -y \
        postgresql-server-dev-${PG_MAJOR} \
        build-essential \
        git \
    # Install pg_cron (pinned to ${PG_CRON_SHA} on main)
    && git clone https://github.com/citusdata/pg_cron.git \
    && cd pg_cron && git checkout ${PG_CRON_SHA} \
    && make && make install \
    && cd .. && rm -rf pg_cron \
    # Install pgTAP (pinned to ${PGTAP_REF})
    && git clone --depth 1 --branch ${PGTAP_REF} https://github.com/theory/pgtap.git \
    && cd pgtap \
    && make && make install \
    && cd .. && rm -rf pgtap \
    # Install pg_prove for running tests
    && apt-get install -y libtap-parser-sourcehandler-pgtap-perl \
    # Clean up
    && apt-get remove -y build-essential git \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# pg_cron and pg_stat_statements require preloading
RUN echo "shared_preload_libraries = 'pg_cron,pg_stat_statements'" >> /usr/share/postgresql/postgresql.conf.sample \
    && echo "cron.database_name = 'postgres'" >> /usr/share/postgresql/postgresql.conf.sample
