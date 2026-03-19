#!/bin/bash
set -Eeuo pipefail

# Minimal PostgreSQL startup script with full paths
#
# This script is responsible for:
#  - starting PostgreSQL (or reusing an existing instance)
#  - ensuring the database + role exist and have correct privileges
#  - ensuring the Notes app schema exists and is up-to-date (tables, constraints, indexes, triggers)
#
# Conventions:
#  - Writes a psql connection command to db_connection.txt
#  - Writes a db_visualizer/postgres.env file for the bundled DB viewer

# Allow orchestrator/runtime to override defaults via standard env vars.
DB_NAME="${POSTGRES_DB:-myapp}"
DB_USER="${POSTGRES_USER:-appuser}"
DB_PASSWORD="${POSTGRES_PASSWORD:-dbuser123}"
DB_PORT="${POSTGRES_PORT:-5000}"

PGDATA_DIR="/var/lib/postgresql/data"

on_error() {
    echo "❌ startup.sh failed (line ${BASH_LINENO[0]}): ${BASH_COMMAND}" >&2
}
trap on_error ERR

echo "Starting PostgreSQL setup..."

# Find PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Found PostgreSQL version: ${PG_VERSION}"

# Track whether we should start a new server or reuse an existing one.
POSTGRES_ALREADY_RUNNING="false"

ensure_pg_networking() {
    # Ensures Postgres listens on all interfaces and accepts password auth from other containers.
    # This is important for multi-container (backend ↔ db) setups.
    #
    # Idempotent: uses a marker comment to avoid duplicate entries.

    local conf="${PGDATA_DIR}/postgresql.conf"
    local hba="${PGDATA_DIR}/pg_hba.conf"

    if [ ! -f "${conf}" ] || [ ! -f "${hba}" ]; then
        echo "PostgreSQL config files not found yet; networking config will be applied after initdb."
        return 0
    fi

    # Ensure listen_addresses = '*'
    if grep -Eq "^[#[:space:]]*listen_addresses[[:space:]]*=" "${conf}"; then
        # Replace any existing listen_addresses line (commented or not)
        sed -i "s/^[#[:space:]]*listen_addresses[[:space:]]*=.*/listen_addresses = '*'/" "${conf}"
    else
        echo "listen_addresses = '*'" >> "${conf}"
    fi

    # Ensure we can connect from other containers using password auth.
    if ! grep -q "kavia-notes-app: remote access" "${hba}"; then
        cat >> "${hba}" <<'EOF'

# kavia-notes-app: remote access (password auth) for inter-container connectivity
host    all             all             0.0.0.0/0               md5
host    all             all             ::/0                    md5
EOF
    fi
}

ensure_schema() {
    echo "Ensuring notes app schema exists (users/notes/tags/note_tags, indexes, timestamps)..."

    # Use ON_ERROR_STOP so any failure aborts and returns non-zero.
    # Use a single psql session so we can serialize init and adjust ownership deterministically.
    sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} \
        -v ON_ERROR_STOP=1 \
        -v app_user="${DB_USER}" <<'SQL'
-- Serialize schema initialization to avoid concurrent DDL (e.g., if startup runs twice).
-- Session-level advisory locks are automatically released when this session ends.
SELECT pg_advisory_lock(716483219);

-- Needed for gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Track schema version (lightweight "migrations/init approach" marker)
-- Created as the application role for normal ownership.
SET ROLE :"app_user";
CREATE TABLE IF NOT EXISTS public.schema_migrations (
    version TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO public.schema_migrations(version) VALUES ('0001_initial')
ON CONFLICT (version) DO NOTHING;

-- Generic updated_at trigger function used by multiple tables
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Users table (authentication handled by backend; store password hash)
CREATE TABLE IF NOT EXISTS public.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    display_name TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    last_login_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Notes table
CREATE TABLE IF NOT EXISTS public.notes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    title TEXT NOT NULL DEFAULT '',
    content TEXT NOT NULL DEFAULT '',
    pinned BOOLEAN NOT NULL DEFAULT FALSE,
    favorite BOOLEAN NOT NULL DEFAULT FALSE,
    archived BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Tags table (unique per user via a case-insensitive unique index)
CREATE TABLE IF NOT EXISTS public.tags (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Many-to-many relationship between notes and tags
CREATE TABLE IF NOT EXISTS public.note_tags (
    note_id UUID NOT NULL REFERENCES public.notes(id) ON DELETE CASCADE,
    tag_id UUID NOT NULL REFERENCES public.tags(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (note_id, tag_id)
);

-- If tables existed from older init scripts, make sure new columns exist (idempotent).
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS display_name TEXT,
    ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

ALTER TABLE public.notes
    ADD COLUMN IF NOT EXISTS pinned BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS favorite BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS archived BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

ALTER TABLE public.tags
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Ensure important CHECK constraints exist (Postgres doesn't support ADD CONSTRAINT IF NOT EXISTS)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'users_email_nonempty'
          AND conrelid = 'public.users'::regclass
    ) THEN
        ALTER TABLE public.users
            ADD CONSTRAINT users_email_nonempty
            CHECK (char_length(btrim(email)) > 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'tags_name_nonempty'
          AND conrelid = 'public.tags'::regclass
    ) THEN
        ALTER TABLE public.tags
            ADD CONSTRAINT tags_name_nonempty
            CHECK (char_length(btrim(name)) > 0);
    END IF;
END
$$;

-- Switch back to superuser context to enforce ownership deterministically
RESET ROLE;

-- Ensure app role owns the core objects so it can manage triggers/indexes going forward
ALTER TABLE IF EXISTS public.schema_migrations OWNER TO :"app_user";
ALTER FUNCTION IF EXISTS public.set_updated_at() OWNER TO :"app_user";
ALTER TABLE IF EXISTS public.users OWNER TO :"app_user";
ALTER TABLE IF EXISTS public.notes OWNER TO :"app_user";
ALTER TABLE IF EXISTS public.tags OWNER TO :"app_user";
ALTER TABLE IF EXISTS public.note_tags OWNER TO :"app_user";

-- Create indexes / triggers as the application role (owner), idempotently.
SET ROLE :"app_user";

-- =========
-- Indexes (idempotent)
-- =========

-- Case-insensitive uniqueness for user email
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_ci
    ON public.users ((lower(email)));

-- Helpful lookup/sort indexes for notes
CREATE INDEX IF NOT EXISTS idx_notes_user_id
    ON public.notes (user_id);

CREATE INDEX IF NOT EXISTS idx_notes_user_updated_at
    ON public.notes (user_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_notes_user_pinned
    ON public.notes (user_id)
    WHERE pinned = TRUE AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_notes_user_favorite
    ON public.notes (user_id)
    WHERE favorite = TRUE AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_notes_user_archived
    ON public.notes (user_id)
    WHERE archived = TRUE AND deleted_at IS NULL;

-- Full-text search index for title/content (ignores soft-deleted notes)
CREATE INDEX IF NOT EXISTS idx_notes_search_gin
    ON public.notes
    USING GIN (to_tsvector('english', coalesce(title,'') || ' ' || coalesce(content,'')))
    WHERE deleted_at IS NULL;

-- Tags: unique per user (case-insensitive)
CREATE UNIQUE INDEX IF NOT EXISTS idx_tags_user_name_ci
    ON public.tags (user_id, (lower(name)));

CREATE INDEX IF NOT EXISTS idx_tags_user_id
    ON public.tags (user_id);

-- Join-table lookups
CREATE INDEX IF NOT EXISTS idx_note_tags_tag_id
    ON public.note_tags (tag_id);

-- =========
-- updated_at triggers (drop/create is deterministic)
-- =========
DROP TRIGGER IF EXISTS trg_users_set_updated_at ON public.users;
CREATE TRIGGER trg_users_set_updated_at
BEFORE UPDATE ON public.users
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_notes_set_updated_at ON public.notes;
CREATE TRIGGER trg_notes_set_updated_at
BEFORE UPDATE ON public.notes
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_tags_set_updated_at ON public.tags;
CREATE TRIGGER trg_tags_set_updated_at
BEFORE UPDATE ON public.tags
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

RESET ROLE;

-- Release advisory lock
SELECT pg_advisory_unlock(716483219);
SQL

    echo "✓ Schema ensured."
}

# Check if PostgreSQL is already running on the specified port
if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
    echo "PostgreSQL is already running on port ${DB_PORT}!"
    echo "Database: ${DB_NAME}"
    echo "User: ${DB_USER}"
    echo "Port: ${DB_PORT}"
    echo ""
    echo "To connect to the database, use:"
    echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"

    # Check if connection info file exists
    if [ -f "db_connection.txt" ]; then
        echo "Or use: $(cat db_connection.txt)"
    fi

    echo ""
    echo "Continuing to verify DB/user and ensure schema..."
    POSTGRES_ALREADY_RUNNING="true"
fi

# Also check if there's a PostgreSQL process running (in case pg_isready fails)
if pgrep -f "postgres.*-p ${DB_PORT}" > /dev/null 2>&1; then
    echo "Found existing PostgreSQL process on port ${DB_PORT}"
    echo "Attempting to verify connection..."
    POSTGRES_ALREADY_RUNNING="true"

    # Try to connect and verify the database exists (do not exit if it fails; we may need to create DB)
    if sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} -c '\q' 2>/dev/null; then
        echo "Database ${DB_NAME} is accessible."
    fi
fi

if [ "${POSTGRES_ALREADY_RUNNING}" != "true" ]; then
    # Initialize PostgreSQL data directory if it doesn't exist
    if [ ! -f "${PGDATA_DIR}/PG_VERSION" ]; then
        echo "Initializing PostgreSQL..."
        sudo -u postgres ${PG_BIN}/initdb -D "${PGDATA_DIR}"
    fi

    # Apply networking config (idempotent)
    ensure_pg_networking

    # Start PostgreSQL server in background.
    # -h 0.0.0.0 is important so other containers can connect over the network.
    echo "Starting PostgreSQL server..."
    sudo -u postgres ${PG_BIN}/postgres -D "${PGDATA_DIR}" -p "${DB_PORT}" -h 0.0.0.0 &

    # Wait briefly before readiness checks
    echo "Waiting for PostgreSQL to start..."
    sleep 2
else
    echo "Reusing existing PostgreSQL server on port ${DB_PORT}..."
fi

# Check if PostgreSQL is running/ready
for i in {1..30}; do
    if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
        echo "PostgreSQL is ready!"
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 1
done

# Create database and user
echo "Setting up database and user..."

# Create DB (idempotent)
sudo -u postgres ${PG_BIN}/createdb -p ${DB_PORT} ${DB_NAME} 2>/dev/null || echo "Database might already exist"

# Set up user and permissions with proper schema ownership
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d postgres -v ON_ERROR_STOP=1 << EOF
-- Create user if doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;

-- Make app user the DB owner (helps with future DDL/trigger management)
ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};

-- Grant database-level permissions
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Connect to the specific database for schema-level permissions
\\c ${DB_NAME}

-- For PostgreSQL 15+, we need to handle public schema permissions differently
-- First, grant usage on public schema
GRANT USAGE ON SCHEMA public TO ${DB_USER};

-- Grant CREATE permission on public schema
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Make the user owner of all future objects they create in public schema
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};

-- Alternative: Grant all privileges on schema public to the user
GRANT ALL ON SCHEMA public TO ${DB_USER};

-- Ensure the user can work with any existing objects
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
EOF

# Additionally, connect to the specific database to ensure permissions
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} -v ON_ERROR_STOP=1 << EOF
-- Double-check permissions are set correctly in the target database
GRANT ALL ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Show current permissions for debugging
\\dn+ public
EOF

# Ensure the full application schema exists.
ensure_schema

# Save connection command to a file
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables to a file
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo ""

echo "Environment variables saved to db_visualizer/postgres.env"
echo "To use with Node.js viewer, run: source db_visualizer/postgres.env"

echo "To connect to the database, use one of the following commands:"
echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
echo "$(cat db_connection.txt)"
