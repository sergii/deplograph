# Deplograph runtime collectors (PR #6)

Two **one-shot, read-only** Ruby collectors are included here. They are not Rails
controllers and must run next to the runtime whose state is being observed.
No production collector is deployed by this PR.

Both post to \`POST /api/v1/integration_events\` using an organization credential
with \`observe\`, the matching provider (\`kubernetes\` or \`kamal_agent\`) and
repository/environment allowlists. Tokens should be distinct per cluster or
Kamal host and created with \`bin/rails identity:issue\`. Tokens are still
bearer secrets; provider identity is not a hardware attestation.

## Kubernetes

Use the sample \`collectors/examples/kubernetes-observer.yaml\` as a starting
point; it includes a ServiceAccount, namespace-scoped Role/RoleBinding and
a five-minute CronJob. Replace the placeholder container image with a
prebuilt, version-pinned image containing Ruby and this folder. Create the
token Secret out-of-band. It is deliberately not checked into this repo.

Required environment:
- \`DEPLOGRAPH_URL\` - HTTPS Deplograph integration-events URL
- \`DEPLOGRAPH_TOKEN\` - scoped observe token for \`kubernetes\`
- \`DEPLOGRAPH_REPOSITORY\` - repo owning the workload, e.g. \`acme/payments\`
- \`DEPLOGRAPH_ENVIRONMENT\` - \`staging\`, \`production\`, etc.
- \`DEPLOGRAPH_NAMESPACE\` - namespace to list
- \`KUBERNETES_SERVICE_HOST\` (usually set by Kubernetes)

Optional: \`KUBERNETES_SERVICE_PORT\`, \`KUBERNETES_CA_FILE\`,
\`KUBERNETES_TOKEN_FILE\`, \`DEPLOGRAPH_POD_SELECTOR\`.
Execute \`ruby collectors/bin/kubernetes_observe\`.

The collector reads only Pod status / labels, not Pod specs, ConfigMaps or
Secrets. It picks the actual \`status.containerStatuses[].imageID\` only if
it unambiguously identifies a registry \`repo@sha256:digest\` image.
Runtime-specific opaque IDs such as \`containerd://sha256:...\` are **not**
promoted to registry digests. Pods without resolved digests are skipped;
the submitted results are always marked \`coverage=partial\`.

## Kamal 2

Run \`ruby collectors/bin/kamal_observe\` on each relevant host, using a Ruby
runtime and local Docker CLI. Never give the Rails server access to the Docker
socket. A host operator should schedule the command and configure it with:

- \`DEPLOGRAPH_URL\`, \`DEPLOGRAPH_TOKEN\`, \`DEPLOGRAPH_REPOSITORY\`,
  \`DEPLOGRAPH_ENVIRONMENT\`, as above (provider \`kamal_agent\`)
- \`KAMAL_SERVICE\` - expected Docker label \`service\`
- \`KAMAL_IMAGE_REPOSITORY\` - e.g. \`ghcr.io/acme/payments\`
- Optional \`KAMAL_DESTINATION\`, \`KAMAL_HOST_ID\`

It enumerates **running** service-labeled containers, verifies their labels
and resolves a uniquely matching \`RepoDigests\` entry from Docker image inspect.
The container's local \`Image\` SHA is **not** treated as a registry manifest
digest. Containers with missing/ambiguous RepoDigests are skipped.

## Trust and completeness

Each observation contains a per-instance identity and a logical workload
so a multi-replica service is not reduced to one observation. It still
provides partial, point-in-time evidence. Observations do not prove the
full desired replica count, successful rollout, or that a container is still
running five minutes later. Missing observations are not proof of absence.
Neither collector reads or transmits ENV values.

The API uses source-bound bearer tokens. A token compromise allows forged
observations within the token's scope. Consider short-lived signed
attestations, cluster-specific identity, coverage reports and agent
heartbeat before any production-grade verification claims.
