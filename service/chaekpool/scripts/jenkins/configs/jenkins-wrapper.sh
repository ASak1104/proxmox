#!/bin/sh
# Jenkins wrapper script for supervise-daemon

export JENKINS_HOME="/var/lib/jenkins"
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk"

cd "$JENKINS_HOME"
exec /usr/bin/java -Xmx1024m -Djava.awt.headless=true -jar /opt/jenkins/jenkins.war --httpPort=8080
