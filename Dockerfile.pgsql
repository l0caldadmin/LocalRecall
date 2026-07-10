FROM ubuntu:26.04

# Set environment variables to non-interactive to prevent prompts
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install necessary packages
RUN apt-get update && \
    apt-get install -y \
        git \
        tzdata \
        curl \
        make \
        gcc \
        pkg-config \
        clang \
        libssl-dev \
        lsb-release \
        software-properties-common \
        postgresql-common \
        jq \
        build-essential \
        gosu \
    && rm -rf /var/lib/apt/lists/*

# Create postgres user with specific UID/GID (999:999) for Kubernetes compatibility
RUN if ! getent group postgres > /dev/null 2>&1; then \
        groupadd -r postgres --gid=999; \
    else \
        groupmod -g 999 postgres 2>/dev/null || true; \
    fi && \
    if ! getent passwd postgres > /dev/null 2>&1; then \
        useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres; \
    else \
        usermod -u 999 -g postgres postgres 2>/dev/null || true; \
    fi

# Modernized: Securely download PostgreSQL signing key and add the repository
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/pgdg.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update

# Install PostgreSQL 18, contrib modules, pgvector, and timescaledb
RUN apt-get install -y \
        postgresql-18 \
        postgresql-contrib-18 \
        postgresql-18-pgvector \
        postgresql-18-timescaledb \
        postgresql-server-dev-18 \
    && rm -rf /var/lib/apt/lists/*

# Ensure PostgreSQL binaries are in the PATH
ENV PATH="/usr/lib/postgresql/18/bin:${PATH}"

# Build and install pg_textsearch extension
ARG PG_TEXTSEARCH_VERSION=v1.3.1
RUN git clone --depth 1 --branch "${PG_TEXTSEARCH_VERSION}" https://github.com/timescale/pg_textsearch /tmp/pg_textsearch && \
    cd /tmp/pg_textsearch && \
    make && \
    make install && \
    cd / && \
    rm -rf /tmp/pg_textsearch

# Install Rust (required for pgvectorscale)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal && \
    . $HOME/.cargo/env && \
    rustup default stable && \
    rustup target add $(rustc -vV | grep host | cut -d' ' -f2)
ENV PATH="/root/.cargo/bin:${PATH}"
ENV CARGO_TARGET_DIR="/tmp/cargo-target"

# Build and install pgvectorscale extension
RUN cd /tmp && \
    git clone --depth 1 https://github.com/timescale/pgvectorscale && \
    cd pgvectorscale/pgvectorscale && \
    PGRX_VERSION=$(cargo metadata --format-version 1 2>/dev/null | jq -r '.packages[] | select(.name == "pgrx") | .version' 2>/dev/null || \
    grep -E 'pgrx\s*=\s*"' Cargo.toml | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || echo "0.11.8") && \
    echo "Installing cargo-pgrx version: $PGRX_VERSION" && \
    cargo install --locked cargo-pgrx --version "$PGRX_VERSION" && \
    cargo pgrx init --pg18 $(which pg_config) && \
    cargo pgrx install --release && \
    cd / && \
    rm -rf /tmp/pgvectorscale \
    rm -rf /root/.cargo

# Create standard PostgreSQL runtime directories
RUN mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql

# Set up PostgreSQL data directory variables
ENV PGDATA=/var/lib/postgresql/data
ENV POSTGRES_DB=localrecall
ENV POSTGRES_USER=localrecall
ENV POSTGRES_PASSWORD=localrecall

RUN mkdir -p "$PGDATA" && \
    chown -R postgres:postgres "$PGDATA" && \
    chmod 700 "$PGDATA"

EXPOSE 5432

USER postgres

# Initialize the database cluster if empty, open local permissions, then boot up
CMD ["sh", "-c", "[ ! -s \"$PGDATA/PG_VERSION\" ] && initdb -D \"$PGDATA\" && echo \"host all all all scram-sha-256\" >> \"$PGDATA/pg_hba.conf\"; postgres -D \"$PGDATA\""]