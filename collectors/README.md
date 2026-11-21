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

## ENV names-only collector (PR #7)

\`ruby collectors/bin/env_keys_observe\` collects variable **names only**
from its own executing Ruby process, using \`ENV.keys\` and excluding
\`DEPLOGRAPH_*\` collector settings. No variable value is read, hashed,
logged, transmitted, or persisted.

Required: \`DEPLOGRAPH_CONFIG_URL\` (e.g.
\`https://deplograph.example/api/v1/configuration_snapshots\`),
\`DEPLOGRAPH_TOKEN\` with \`observe\`, \`DEPLOGRAPH_COLLECTOR_SOURCE\` in
\`kubernetes\`, \`kamal_agent\`, \`docker_agent\`,
\`DEPLOGRAPH_REPOSITORY\`, \`DEPLOGRAPH_ENVIRONMENT\`,
\`DEPLOGRAPH_WORKLOAD\`.

The collector **does not** read ENV of PID 1 or arbitrary containers and
always sends \`scope=process\`, \`completeness=partial\`. Run in the
application's actual configuration context and treat results as
supplementary. If run in its own Kubernetes CronJob, its variables
belong to the CronJob, not the application.

For declared configuration, \`POST /api/v1/configuration_snapshots\` with
\`scope=declared\`, \`source=github_actions\` and a \`report\` token.
Collect only names from a trusted config parser, never raw values.
\`envFrom\` references and external secret stores can make declared key
coverage partial unless resolved independently with appropriate access.


## Opt-in HMAC value fingerprints (PR #8)

Run \`ruby collectors/bin/env_fingerprints_observe\` explicitly only in the
process context whose variables you intend to compare. It uses \`ENV.keys\`
plus local HMAC-SHA256 over the selected values, then sends only names and
hexadecimal keyed fingerprints through two HTTPS API requests.

Provide the collector settings from the root README and a key file at
\`DEPLOGRAPH_HMAC_KEY_FILE\`, plus a stable \`DEPLOGRAPH_HMAC_KEY_ID\`.
The file must contain at least 32 random bytes. Never pass the secret in
command-line arguments or commit it. Securely distribute the **same** key to
environments you compare. Rotate by changing both the file and key ID.

This script reports \`completeness=partial\`: when run outside the target
application process, results say nothing authoritative about its ENV values.
It does not attempt to read other processes, Docker secrets, Kubernetes
Secrets, or remote stores. Any legitimate production collector must be
explicitly integrated into the application execution context.

## Signed Kubernetes control-plane attestor image (PR #13)

This is a **separate, dependency-free Ruby container** for the signed attestation
protocol introduced in PR #11. It does not run Rails, bundle gems, require a
database, mount a Docker socket, or access Kubernetes Secret objects via the API.

Build a local image from the minimal collectors-only context:

```sh
docker build --pull -f collectors/Dockerfile \
  -t deplograph-control-plane-attestor:local collectors
docker run --rm --entrypoint ruby deplograph-control-plane-attestor:local --version
```

The Dockerfile uses Ruby 4.0.10-slim and only the Ruby standard library. The
base is **versioned but not immutable by default**. For an audited deployment,
supply a reviewed `RUBY_BASE_IMAGE=...@sha256:...` at build time and publish
the resulting image to your registry. Pin the *published attestor image*
in `collectors/examples/kubernetes-control-plane-attestor.yaml` with the
**registry manifest digest**, not a tag or a Docker image config hash.
A versioned Dockerfile alone does not make builds bit-for-bit reproducible.

The sample manifest grants namespace-scoped `get/list` access to Deployments,
ReplicaSets and Pods, but not Secrets, ConfigMaps, writes or cluster-wide
resources. The attestor runs as uid/gid 65534 with dropped capabilities,
`RuntimeDefault` seccomp, a read-only root filesystem, bounded resources and
job deadline. The signing private key and scoped Deplograph credential are
mounted from **separate** administrator-created Secrets as read-only files.
The ServiceAccount token is needed for the read-only Kubernetes API. No private
key, observe credential or real cluster configuration is committed to the repo.

The token is read from `DEPLOGRAPH_TOKEN_FILE` when provided. The legacy
`DEPLOGRAPH_TOKEN` environment variable remains supported for pre-existing
one-shot integrations, but the CronJob example uses the secret file instead.
The signing key must be an Ed25519 private key, registered separately by an
organization owner/admin as its **public** key via `/runtime_attestors`.
`resolution_enabled` is opt-in, not set by this image or manifest.

### Actual Kubernetes API smoke test in kind

`.github/workflows/attestor-kind-smoke.yml` builds this container, starts a
throwaway kind cluster and executes `collectors/smoke/kind_attestor_smoke.sh`.
The script provisions two real Deployments (web with 2 replicas, worker with
1 replica), scoped RBAC, and ephemeral fake keys/credentials. It exercises
the **real** Kubernetes HTTPS control-plane API from an attestor Job:

- verifies read-only RBAC and rejection of Secret/pod-write permissions;
- checks the full pinned workload coverage contract when `imageID` contains
  a verifiable registry manifest digest;
- **expects rejection** instead when kind/containerd exposes only an opaque
  image config/container ID; no fake manifest digest is substituted;
- scales down web to check that an incomplete rollout is always rejected;
- runs the Job with the same non-root image and security constraints as
  the production example, but overrides the entrypoint to a probe that
  **does not sign or transmit data**.

To run locally, provision a disposable kind cluster, build and load the image
as shown in the workflow, and run `bash collectors/smoke/kind_attestor_smoke.sh`.
The namespace contains only synthetic resources, and the smoke CronJob is
suspended to prevent outbound publishes. This is **not** an end-to-end
production proof: real network delivery to a Rails installation, public key
enrollment, production key custody, deployment mapping, GitHub App setup and
a live `resolved/reopen` transition are not exercised by kind. Signed
submission and resolution rules are separately covered by Rails integration
tests and still require a deployment smoke test before enabling production
automatic resolution.
