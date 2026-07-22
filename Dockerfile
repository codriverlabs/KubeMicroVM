# Stage 1: Build native image
FROM quay.io/quarkus/ubi9-quarkus-mandrel-builder-image:jdk-25 AS builder

COPY --chown=quarkus:quarkus . /code
WORKDIR /code

USER quarkus

RUN ./mvnw package -pl operator-controller -am -Dnative \
    -DskipTests \
    -Dquarkus.native.container-build=false

# Stage 2: Runtime
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.4

ARG APP_DIR=/deployments

WORKDIR ${APP_DIR}

COPY --from=builder /code/operator-controller/target/*-runner ${APP_DIR}/application

RUN chmod 775 ${APP_DIR}/application && \
    chown 1001:root ${APP_DIR}/application

USER 1001

EXPOSE 8080 8443

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/q/health/live || exit 1

LABEL org.opencontainers.image.source="https://github.com/codriverlabs/KubeMicroVM" \
      org.opencontainers.image.description="KubeMicroVM Operator - Kubernetes operator for AWS Lambda MicroVMs"

ENTRYPOINT ["./application"]
