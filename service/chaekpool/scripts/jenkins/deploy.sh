#!/bin/bash
# Jenkins 배포 (CT 230, 10.1.0.130)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

CP_ENV="${SCRIPT_DIR}/../../.chaekpool.env"
[ -f "${CP_ENV}" ] && source "${CP_ENV}"

CT_ID="${CT_JENKINS}"
JENKINS_VERSION="2.541.1"
PLUGIN_MANAGER_VERSION="2.14.0"

echo "=== Deploying Jenkins to CT ${CT_ID} ==="

echo "[1/6] Installing Java and creating user..."
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

echo "[2/6] Downloading Jenkins WAR v${JENKINS_VERSION}..."
pct_script "${CT_ID}" <<SCRIPT
set -e

wget -q -O /opt/jenkins/jenkins.war \
    "https://get.jenkins.io/war-stable/${JENKINS_VERSION}/jenkins.war"
chown jenkins:jenkins /opt/jenkins/jenkins.war
chmod 644 /opt/jenkins/jenkins.war

echo "Jenkins WAR downloaded"
SCRIPT

echo "[3/6] Installing plugins (oic-auth, configuration-as-code)..."
pct_script "${CT_ID}" <<SCRIPT
set -e

wget -q -O /tmp/jenkins-plugin-manager.jar \
    "https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/${PLUGIN_MANAGER_VERSION}/jenkins-plugin-manager-${PLUGIN_MANAGER_VERSION}.jar"

java -jar /tmp/jenkins-plugin-manager.jar \
    -w /opt/jenkins/jenkins.war \
    -d /var/lib/jenkins/plugins \
    -p oic-auth configuration-as-code

chown -R jenkins:jenkins /var/lib/jenkins/plugins
rm -f /tmp/jenkins-plugin-manager.jar

echo "Plugins installed"
SCRIPT

echo "[4/6] Deploying configuration files..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/casc.yaml" "/var/lib/jenkins/casc.yaml"
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/jenkins-wrapper.sh" "/opt/jenkins/jenkins-wrapper.sh"

echo "[5/6] Injecting secrets..."
pct_script "${CT_ID}" <<SCRIPT
set -e

sed -i "s|__OIDC_JENKINS_SECRET__|${AUTHELIA_OIDC_JENKINS_SECRET}|g" /var/lib/jenkins/casc.yaml

chown jenkins:jenkins /var/lib/jenkins/casc.yaml
chmod 600 /var/lib/jenkins/casc.yaml
chmod 755 /opt/jenkins/jenkins-wrapper.sh
chown jenkins:jenkins /opt/jenkins/jenkins-wrapper.sh

echo "Configuration deployed"
SCRIPT

echo "[6/6] Deploying service and starting..."
pct_push "${CT_ID}" "${SCRIPT_DIR}/configs/jenkins.openrc" "/etc/init.d/jenkins"

pct_script "${CT_ID}" <<'SCRIPT'
set -e
chmod 755 /etc/init.d/jenkins
rc-service jenkins restart 2>/dev/null || rc-service jenkins start
rc-update add jenkins
rc-service jenkins status
echo "Jenkins is ready"
SCRIPT

echo "=== Jenkins deployed ==="
