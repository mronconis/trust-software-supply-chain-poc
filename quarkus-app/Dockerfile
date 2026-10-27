# --- Stage 1: Build ---
FROM registry.access.redhat.com/ubi9/openjdk-17:latest AS builder
USER root
WORKDIR /build
COPY pom.xml .
COPY src ./src
RUN mvn package -DskipTests

# --- Stage 2: Runtime ---
FROM registry.access.redhat.com/ubi9/openjdk-17-runtime:latest
WORKDIR /deployments
COPY --from=builder /build/target/quarkus-app/ ./

EXPOSE 8080
ENV JAVA_OPTS_APPEND="-Dquarkus.http.host=0.0.0.0"
ENTRYPOINT ["java", "-jar", "quarkus-run.jar"]
