# syntax=docker/dockerfile:1
# This image has no Rails, database, or external gem dependencies.
# For production builds, pin the base to an audited immutable @sha256 digest.
ARG RUBY_BASE_IMAGE=ruby:4.0.10-slim
FROM ${RUBY_BASE_IMAGE}

WORKDIR /app
COPY --chown=65534:65534 bin/ /app/collectors/bin/
COPY --chown=65534:65534 lib/ /app/collectors/lib/

ENV HOME=/tmp
USER 65534:65534
ENTRYPOINT ["ruby", "/app/collectors/bin/kubernetes_control_plane_attest"]
