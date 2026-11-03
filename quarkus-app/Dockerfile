# --- Stage 1: Build ---
FROM registry.access.redhat.com/ubi9/openjdk-17:latest AS builder
USER root
WORKDIR /build
RUN microdnf install -y zip && microdnf clean all
COPY pom.xml .
COPY src ./src
RUN mvn package -DskipTests

# Remedition Log4jShell: removed vulnerable JNDI class from jar file
RUN zip -q -d /build/target/quarkus-app/lib/main/org.apache.logging.log4j.log4j-core-*.jar org/apache/logging/log4j/core/lookup/JndiLookup.class || true

# --- Stage 2: Runtime ---
FROM registry.access.redhat.com/ubi9/openjdk-17-runtime:latest
WORKDIR /deployments
COPY --from=builder /build/target/quarkus-app/ ./

EXPOSE 8080
ENV JAVA_OPTS_APPEND="-Dquarkus.http.host=0.0.0.0 -Dlog4j2.formatMsgNoLookups=true"

ENTRYPOINT ["java", "-jar", "quarkus-run.jar"]
