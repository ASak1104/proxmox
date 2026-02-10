#!/bin/bash
# PostgreSQL + pgAdmin 4 배포 (CT 210, 10.0.1.110)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

CP_ENV="${SCRIPT_DIR}/../../.chaekpool.env"
[ -f "${CP_ENV}" ] && source "${CP_ENV}"

CT_ID="${CT_POSTGRESQL}"

echo "=== Deploying PostgreSQL + pgAdmin to CT ${CT_ID} ==="

echo "[1/6] Installing PostgreSQL and initializing DB..."
pct_script "${CT_ID}" <<SCRIPT
set -e

apk update
apk add --no-cache postgresql postgresql-client

# Create data directory
mkdir -p /var/lib/postgresql/18/data
chown -R postgres:postgres /var/lib/postgresql
chmod 700 /var/lib/postgresql/18/data

# Initialize database (skip if already initialized)
if [ ! -f /var/lib/postgresql/18/data/postgresql.conf ]; then
    su - postgres -s /bin/sh -c \
        "initdb -D /var/lib/postgresql/18/data -U postgres --locale=en_US.UTF-8 --encoding=UTF-8"
fi

# Configure listen_addresses and port
sed -i "s/^#listen_addresses = .*/listen_addresses = '*'/" /var/lib/postgresql/18/data/postgresql.conf
sed -i "s/^#port = .*/port = ${PORT_POSTGRESQL}/" /var/lib/postgresql/18/data/postgresql.conf

echo "PostgreSQL initialized"
SCRIPT

echo "[2/6] Deploying pg_hba.conf..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/pg_hba.conf" "/var/lib/postgresql/18/data/pg_hba.conf"
pct_exec "${CT_ID}" "chown postgres:postgres /var/lib/postgresql/18/data/pg_hba.conf && chmod 640 /var/lib/postgresql/18/data/pg_hba.conf"

echo "[3/6] Deploying PostgreSQL OpenRC service..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/postgresql.openrc" "/etc/init.d/postgresql"
pct_exec "${CT_ID}" "chmod 755 /etc/init.d/postgresql"

echo "[4/6] Starting PostgreSQL and creating database..."
pct_script "${CT_ID}" <<SCRIPT
set -e

rc-service postgresql start
rc-update add postgresql

# Wait for PostgreSQL to be ready
i=0; while [ \$i -lt 30 ]; do
    su - postgres -s /bin/sh -c "pg_isready -q" && break
    sleep 1; i=\$((i + 1))
done

# Create user and database (ignore errors if already exist)
su - postgres -s /bin/sh -c "psql -c \"CREATE USER ${PG_USER} WITH PASSWORD '${PG_PASSWORD}';\"" 2>/dev/null || true
su - postgres -s /bin/sh -c "psql -c \"CREATE DATABASE ${PG_DB} OWNER ${PG_USER} ENCODING 'UTF-8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8';\"" 2>/dev/null || true
su - postgres -s /bin/sh -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE ${PG_DB} TO ${PG_USER};\""

rc-service postgresql status
echo "PostgreSQL is ready"
SCRIPT

echo "[5/6] Installing pgAdmin 4..."
pct_script "${CT_ID}" <<SCRIPT
set -e

apk add --no-cache python3 py3-pip py3-virtualenv postgresql-client \
    build-base python3-dev libffi-dev openssl-dev musl-dev cargo rust

# Create pgAdmin virtualenv
python3 -m venv /opt/pgadmin4/venv
/opt/pgadmin4/venv/bin/pip install --upgrade pip
/opt/pgadmin4/venv/bin/pip install pgadmin4 gunicorn

# Create pgAdmin user
addgroup -S pgadmin 2>/dev/null || true
adduser -S -D -H -h /var/lib/pgadmin -s /sbin/nologin -G pgadmin -g pgadmin pgadmin 2>/dev/null || true

# Create directories
mkdir -p /var/lib/pgadmin /var/log/pgadmin
chown -R pgadmin:pgadmin /var/lib/pgadmin /var/log/pgadmin /opt/pgadmin4

# Configure pgAdmin
cat > /opt/pgadmin4/config_local.py <<PYEOF
import os
SERVER_MODE = True
DEFAULT_SERVER = "0.0.0.0"
DEFAULT_SERVER_PORT = ${PORT_PGADMIN}
DATA_DIR = "/var/lib/pgadmin"
LOG_FILE = "/var/log/pgadmin/pgadmin.log"
SQLITE_PATH = "/var/lib/pgadmin/pgadmin4.db"
SESSION_DB_PATH = "/var/lib/pgadmin/sessions"
STORAGE_DIR = "/var/lib/pgadmin/storage"

AUTHENTICATION_SOURCES = ['oauth2', 'internal']
OAUTH2_AUTO_CREATE_USER = True
OAUTH2_CONFIG = [{
    'OAUTH2_NAME': 'authelia',
    'OAUTH2_DISPLAY_NAME': 'Authelia SSO',
    'OAUTH2_CLIENT_ID': 'pgadmin',
    'OAUTH2_CLIENT_SECRET': '${AUTHELIA_OIDC_PGADMIN_SECRET}',
    'OAUTH2_TOKEN_URL': 'https://auth.cp.codingmon.dev/api/oidc/token',
    'OAUTH2_AUTHORIZATION_URL': 'https://auth.cp.codingmon.dev/api/oidc/authorization',
    'OAUTH2_USERINFO_ENDPOINT': 'https://auth.cp.codingmon.dev/api/oidc/userinfo',
    'OAUTH2_SERVER_METADATA_URL': 'https://auth.cp.codingmon.dev/.well-known/openid-configuration',
    'OAUTH2_SCOPE': 'openid email profile',
}]
PYEOF

# Set initial admin user
PGADMIN_SETUP_EMAIL="${PGADMIN_EMAIL}" \
PGADMIN_SETUP_PASSWORD="${PGADMIN_PASSWORD}" \
PYTHONPATH="/opt/pgadmin4" \
/opt/pgadmin4/venv/bin/python3 -c "
import pgadmin4.setup as setup
setup.setup_db()
"

# setup_db()가 root로 실행되어 생성된 파일 소유권 수정
chown -R pgadmin:pgadmin /var/lib/pgadmin /var/log/pgadmin

# Remove build dependencies
apk del build-base python3-dev libffi-dev openssl-dev musl-dev cargo rust 2>/dev/null || true

echo "pgAdmin 4 installed"
SCRIPT

echo "[6/6] Deploying pgAdmin OpenRC service and starting..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/pgadmin4.openrc" "/etc/init.d/pgadmin4"
pct_exec "${CT_ID}" "chmod 755 /etc/init.d/pgadmin4"

pct_script "${CT_ID}" <<'SCRIPT'
set -e
rc-service pgadmin4 start
rc-update add pgadmin4
rc-service pgadmin4 status
echo "pgAdmin 4 is ready"
SCRIPT

echo "=== PostgreSQL + pgAdmin deployed ==="
