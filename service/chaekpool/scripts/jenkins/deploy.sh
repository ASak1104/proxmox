#!/bin/bash
# Jenkins 배포 (CT 230, 10.0.1.130)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

CT_ID="${CT_JENKINS}"
JENKINS_VERSION="2.541.1"

echo "=== Deploying Jenkins to CT ${CT_ID} ==="

echo "[1/4] Installing Java and creating user..."
pct_script "${CT_ID}" <<'SCRIPT'
set -e

apk update
apk add --no-cache openjdk17 fontconfig freetype ttf-dejavu

addgroup -S jenkins 2>/dev/null || true
adduser -S -D -h /var/lib/jenkins -s /sbin/nologin -G jenkins -g jenkins jenkins 2>/dev/null || true

mkdir -p /var/lib/jenkins /opt/jenkins /var/log/jenkins
chown -R jenkins:jenkins /var/lib/jenkins /opt/jenkins /var/log/jenkins

echo "Java and user created"
SCRIPT

echo "[2/4] Downloading Jenkins WAR v${JENKINS_VERSION}..."
pct_script "${CT_ID}" <<SCRIPT
set -e

wget -q -O /opt/jenkins/jenkins.war \
    "https://get.jenkins.io/war-stable/${JENKINS_VERSION}/jenkins.war"
chown jenkins:jenkins /opt/jenkins/jenkins.war
chmod 644 /opt/jenkins/jenkins.war

echo "Jenkins WAR downloaded"
SCRIPT

echo "[3/4] Deploying wrapper script..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/jenkins-wrapper.sh" "/opt/jenkins/jenkins-wrapper.sh"

pct_script "${CT_ID}" <<'SCRIPT'
set -e
chmod 755 /opt/jenkins/jenkins-wrapper.sh
chown jenkins:jenkins /opt/jenkins/jenkins-wrapper.sh
echo "Wrapper script deployed"
SCRIPT

echo "[4/4] Deploying service and starting..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/jenkins.openrc" "/etc/init.d/jenkins"

pct_script "${CT_ID}" <<'SCRIPT'
set -e
chmod 755 /etc/init.d/jenkins
rc-service jenkins start
rc-update add jenkins
rc-service jenkins status
echo "Jenkins is ready"
SCRIPT

echo "=== Jenkins deployed ==="
