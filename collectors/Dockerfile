# This image has no Rails, database, or external gem dependencies.
# The Ruby base is pinned to an OCI registry manifest digest, not a mutable tag.
ARG RUBY_BASE_IMAGE=ruby:4.0.10-slim@sha256:a4b3e62bfe56bd267a3aeacc1b89aea96be919faa0c7d77c6346e2ac14f6c175
FROM ${RUBY_BASE_IMAGE}

WORKDIR /app
COPY --chown=65534:65534 bin/ /app/collectors/bin/
COPY --chown=65534:65534 lib/ /app/collectors/lib/

ENV HOME=/tmp
USER 65534:65534
ENTRYPOINT ["ruby", "/app/collectors/bin/kubernetes_control_plane_attest"]
