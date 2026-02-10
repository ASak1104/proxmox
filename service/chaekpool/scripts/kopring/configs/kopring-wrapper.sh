#!/bin/sh
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk"
export SPRING_DATASOURCE_URL="jdbc:postgresql://10.1.0.110:5432/chaekpool"
export SPRING_DATASOURCE_USERNAME="chaekpool"
export SPRING_DATASOURCE_PASSWORD="changeme"
export SPRING_REDIS_HOST="10.1.0.111"
export SPRING_REDIS_PORT="6379"
export SPRING_REDIS_PASSWORD="changeme"
export SERVER_PORT="8080"

exec /usr/bin/java -Xms256m -Xmx512m -jar /opt/kopring/app.jar --spring.config.additional-location=file:/opt/kopring/application.yml "$@"
