#!/bin/bash
# Valkey + Redis Commander 배포 (CT 211, 10.0.1.111)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

CT_ID="${CT_VALKEY}"

echo "=== Deploying Valkey + Redis Commander to CT ${CT_ID} ==="

echo "[1/5] Installing Valkey and creating directories..."
pct_script "${CT_ID}" <<'SCRIPT'
set -e

apk update
apk add --no-cache valkey

mkdir -p /var/lib/valkey /var/log/valkey /etc/valkey
chown -R valkey:valkey /var/lib/valkey /var/log/valkey /etc/valkey

echo "Valkey installed"
SCRIPT

echo "[2/5] Deploying Valkey configs..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/valkey.conf"   "/etc/valkey/valkey.conf"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/valkey.openrc" "/etc/init.d/valkey"

pct_script "${CT_ID}" <<'SCRIPT'
set -e
chown valkey:valkey /etc/valkey/valkey.conf
chmod 640 /etc/valkey/valkey.conf
chmod 755 /etc/init.d/valkey
SCRIPT

echo "[3/5] Starting Valkey service..."
pct_script "${CT_ID}" <<'SCRIPT'
set -e
rc-service valkey start
rc-update add valkey
rc-service valkey status
echo "Valkey is ready"
SCRIPT

echo "[4/5] Installing Redis Commander..."
pct_script "${CT_ID}" <<'SCRIPT'
set -e

apk add --no-cache nodejs npm

npm install -g redis-commander

# Create service user
addgroup -S rediscmd 2>/dev/null || true
adduser -S -D -H -h /dev/null -s /sbin/nologin -G rediscmd -g rediscmd rediscmd 2>/dev/null || true

echo "Redis Commander installed"
SCRIPT

echo "[5/5] Deploying Redis Commander OpenRC service and starting..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/redis-commander.openrc" "/etc/init.d/redis-commander"
pct_exec "${CT_ID}" "chmod 755 /etc/init.d/redis-commander"

pct_script "${CT_ID}" <<'SCRIPT'
set -e
rc-service redis-commander start
rc-update add redis-commander
rc-service redis-commander status
echo "Redis Commander is ready"
SCRIPT

echo "=== Valkey + Redis Commander deployed ==="
