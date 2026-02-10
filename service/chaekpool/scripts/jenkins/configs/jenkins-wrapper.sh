#!/bin/sh
# Jenkins wrapper script for supervise-daemon

export JENKINS_HOME="/var/lib/jenkins"
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk"
export CASC_JENKINS_CONFIG="/var/lib/jenkins/casc.yaml"

cd "$JENKINS_HOME"
exec /usr/bin/java -Xmx1024m \
    -Djava.awt.headless=true \
    -Djenkins.install.runSetupWizard=false \
    -jar /opt/jenkins/jenkins.war --httpPort=8080
