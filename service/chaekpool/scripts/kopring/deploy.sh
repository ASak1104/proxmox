#!/bin/bash
# Kopring Spring Boot 배포 (CT 240, 10.0.1.140)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

CT_ID="${CT_KOPRING}"
GIT_REPO="https://github.com/your-org/your-kopring-app.git"
GIT_BRANCH="main"

echo "=== Deploying Kopring to CT ${CT_ID} ==="

echo "[1/5] Installing Java and Git..."
pct_script "${CT_ID}" <<'SCRIPT'
set -e

apk update
apk add --no-cache openjdk17-jdk git

echo "JAVA_HOME=/usr/lib/jvm/java-17-openjdk" >> /etc/environment

addgroup -S kopring 2>/dev/null || true
adduser -S -D -H -h /opt/kopring -s /sbin/nologin -G kopring -g kopring kopring 2>/dev/null || true

mkdir -p /opt/kopring
chown -R kopring:kopring /opt/kopring

echo "Java and Git installed"
SCRIPT

echo "[2/5] Cloning repository..."
pct_script "${CT_ID}" <<SCRIPT
set -e

if [ -d /opt/kopring/src/.git ]; then
    cd /opt/kopring/src
    git pull origin ${GIT_BRANCH}
else
    git clone -b ${GIT_BRANCH} ${GIT_REPO} /opt/kopring/src
fi
chown -R kopring:kopring /opt/kopring/src

echo "Repository ready"
SCRIPT

echo "[3/5] Building with Gradle..."
pct_script "${CT_ID}" <<'SCRIPT'
set -e

cd /opt/kopring/src
chmod +x gradlew
JAVA_HOME=/usr/lib/jvm/java-17-openjdk su -s /bin/sh kopring -c \
    "cd /opt/kopring/src && JAVA_HOME=/usr/lib/jvm/java-17-openjdk ./gradlew bootJar --no-daemon"

# Copy built JAR
JAR=$(find /opt/kopring/src/build/libs -name "*.jar" ! -name "*-plain.jar" | head -1)
if [ -n "${JAR}" ]; then
    cp "${JAR}" /opt/kopring/app.jar
    chown kopring:kopring /opt/kopring/app.jar
    chmod 755 /opt/kopring/app.jar
    echo "JAR built: ${JAR}"
else
    echo "ERROR: No JAR found"
    exit 1
fi
SCRIPT

echo "[4/5] Deploying configs..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/application.yml" "/opt/kopring/application.yml"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/kopring-wrapper.sh" "/opt/kopring/kopring-wrapper.sh"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/kopring.openrc"  "/etc/init.d/kopring"

pct_script "${CT_ID}" <<'SCRIPT'
set -e
chown kopring:kopring /opt/kopring/application.yml
chmod 640 /opt/kopring/application.yml
chown kopring:kopring /opt/kopring/kopring-wrapper.sh
chmod 755 /opt/kopring/kopring-wrapper.sh
chmod 755 /etc/init.d/kopring
SCRIPT

echo "[5/5] Starting Kopring service..."
pct_script "${CT_ID}" <<'SCRIPT'
set -e
rc-service kopring start
rc-update add kopring
rc-service kopring status
echo "Kopring is ready"
SCRIPT

echo "=== Kopring deployed ==="
