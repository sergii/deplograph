# Deplograph

**Know what runs where.** Rails 8.1 application for repository inspection, software bill of materials (SBOM) ingestion, dependency graphs, vulnerability matches, and environment-aware deployment reports.

This is a working MVP, not a production-certified vulnerability scanner.

## Stack

- Ruby 4.0.10 (single source of truth: .ruby-version)
- Rails 8.1.4.1 and PostgreSQL 18.7 (local + CI); PostgreSQL 19 GA image pending verification
- Minitest + WebMock for isolated tests
- Active Job using the async adapter for this prototype
- GitHub Actions CI, source SBOM generation and deployment reporting

## Local setup

Prerequisites: Ruby 4.0.10, Bundler and PostgreSQL.

1. Install gems with: bundle install
2. Set DATABASE_URL if your local PostgreSQL connection differs from the default.
3. Prepare DB: bin/rails db:prepare
4. Create your first organization and owner: `bin/rails identity:bootstrap` (interactive password prompt).
5. Alternatively, use `docker compose up --build` for the local Rails + PostgreSQL environment (binds web only on 127.0.0.1).
6. Issue an API token with `bin/rails identity:issue` (see Identity section below), then start web: bin/rails server
7. Open http://localhost:3000 and try the scenarios from examples/README.md.

The application does not automatically load .env.example. Export values or use a secret manager.

## Architecture

- Organization / User / Membership - customer-owned records and browser session identity.
- IntegrationCredential - hashed, revocable provider credentials with repository and environment scopes.
- Application - repository identity and inspected build metadata, unique per organization.
- Artifact - source commit, binary artifact or OCI image identity.
- InventorySnapshot - original SBOM JSON and SHA-256 hash, attached to a specific artifact.
- Component - a package with PURL; ComponentOccurrence - presence in a snapshot.
- DependencyEdge - relationships from CycloneDX or SPDX.
- Environment - production, staging, sandbox, test, preview or development, with optional TTL.
- SourceRevision / Build / Release - commit -> CI build -> logical release with one or more artifacts.
- DeploymentEvent - per-provider evidence, deduplicated by environment, source and event ID.
- DeploymentObservation - per-workload running-image observation, including stale/mixed states.
- GithubInstallation / GithubRepositoryGrant - signed GitHub App installation state and repository grants.
- Deployment - CI report with external deployment ID; GitHub Actions and Kamal events can refer to the same deployment. A report is NOT proof of runtime state.
- VulnerabilityMatch - OSV querybatch result for a versioned package occurrence.

Ingestion does not execute user-supplied SBOM content, Dockerfiles or manifest files.

## Endpoints

All API endpoints require a scoped organization credential (`Authorization: Bearer dpl_...`), with `read`, `report` or `observe` permission.

- POST /api/v1/inventories - CycloneDX JSON or SPDX 2.x JSON for an artifact.
- POST /api/v1/deployments - image digest or commit SHA, provider, environment, deployment ID and time.
- POST /api/v1/environment_events - preview creation/destruction and expiry.
- POST /api/v1/releases - register release, source commit, build and OCI image digests.
- GET /api/v1/releases?repository=acme/app - releases and artifacts.
- POST /api/v1/integration_events - ingest reports and runtime observations from approved providers.
- GET /api/v1/environments?repository=acme/app - evidence-qualified per-environment inventory and findings.
- POST /api/v1/github/webhooks - signed installation and repository grant events (GITHUB_WEBHOOK_SECRET).
- POST /api/v1/repositories/inspect - public GitHub metadata/manifests, or private repositories granted by a verified tenant-bound GitHub App installation.
- GET /up - liveness check.
- GET / - organization-scoped dashboard, requires local password login.
- GET/POST /login and DELETE /logout - login/logout.
- POST /organizations/:id/select - switch between memberships.

Find complete runnable JSON examples, a synthetic artifact relationship graph, and a localhost mock GitHub API in examples/.

OpenAPI 3.1 lives at `public/openapi.yaml`. In development, visit `/api/docs` for read-only Swagger UI (the UI references a CDN). Minitest checks the documented routes and response envelopes; this is not yet full JSON Schema request/response validation.

Run scenario tests: `bin/rails test test/integration/release_lifecycle_test.rb`. They simulate GitHub Actions + Kamal reports, Kubernetes observations, two releases, and environment-specific vulnerability outcomes.

## GitHub Actions

CI runs the Rails test suite with PostgreSQL 18.7 on every PR and every push to main.

The SBOM workflow runs on pushes to main or manually. It uses Syft via anchore/sbom-action to produce CycloneDX JSON, retained as a workflow artifact. When the repository variable DEPLOGRAPH_API_URL and the GitHub Actions secret DEPLOGRAPH_API_TOKEN are configured, it POSTs inventory to Deplograph.

The deployment-report workflow provides an explicit workflow_dispatch action to report an existing deployment for production, staging, sandbox, test or preview. This workflow does not deploy anything. In GitHub Settings > Environments, configure protection rules for sensitive environment names.

The GitHub inspector uses anonymous REST requests for public repositories, or a one-repository-scoped GitHub App installation token for a verified tenant grant. A shared server-side GitHub token is never forwarded to a caller-selected repository. GitHub SBOM reports are processed using GitHub's asynchronous export API.

## Matching with OSV

Set OSV_ENABLED=true to queue matching for imported snapshots. The matcher requests only versioned PURLs through the official OSV querybatch API and handles pagination. An upstream HTTP failure results in a failed match status, never an incorrect "safe" result.

Matching is not exploitability analysis. No claim is made that a component is exploitable in production merely because an advisory matches the version.

## Boundaries / follow-up work

- This MVP does not independently verify running images on Kubernetes/Kamal/AWS.
- No hosted SaaS instance, GitHub sign-in, billing or external secrets store yet.
- The async job backend is not durable across process restarts. Replace it with Solid Queue and recurring retry policies before production.
- Supports CycloneDX component/dependency basics and SPDX 2.x PURLs. SPDX 3.x and full schema validation are future work.
- Local password sign-in and tenant-scoped API are implemented. GitHub App installation onboarding and short-lived repository-scoped tokens are available after configuring GitHub App credentials.
- No production-grade OCI image scanner or real cluster credential flow yet.
- No actual Slack notifications are sent. Slack can be integrated after alert rules and tenant isolation.
- Do not publicly deploy without TLS, rate limits, onboarding/SSO, password reset and session security review.
- Before production use, pin GitHub Actions to reviewed SHAs, set rate limits, audit logs and least-privilege secrets.

## Tests

    bundle install
    RAILS_ENV=test bin/rails db:prepare
    bin/rails test

The tests use WebMock and synthetic SBOMs. They do not contact GitHub or OSV. Root Dockerfile is a baseline prototype, not an audited hardened production image.

## PostgreSQL 19 migration policy

PostgreSQL 19.0 was released on November 19, 2026. As of this change, the official Docker image's stable `postgres:19` tag had not been confirmed in the official-images manifest. Compose therefore defaults to `postgres:18.7` and supports override with `POSTGRES_IMAGE` once GA is published. Do not use a 19 RC image as a substitute for production GA. Major upgrades require a dump/restore or `pg_upgrade`; do not point a new major version at an old volume without an upgrade plan.

## Identity and integration credentials (stacked PR #2)

This PR adds organizations, users, memberships and database-backed scoped API tokens.
The browser dashboard requires local password login. Public signup is intentionally disabled.

Bootstrap the first owner (interactive password prompt, no password in shell history):

    bin/rails identity:bootstrap

Issue a scoped token for API reads and inventory imports:

    ORG=acme NAME="Local API" PROVIDER=api PERMISSIONS=read,report \
      REPOSITORIES=acme/app bin/rails identity:issue

The command displays the token only once. Keep it in a secret manager and export
it as DEPLOGRAPH_API_TOKEN in the client shell. This is not a server setting.

For GitHub Actions, issue a separate PROVIDER=github_actions token with PERMISSIONS=report,
and store it in the repository secret DEPLOGRAPH_API_TOKEN. Kubernetes, Kamal Agent
and other observer sources require their own matching provider credentials with
PERMISSIONS=observe. Reporters cannot claim to have observed running containers.

Revoke with ORG=acme CREDENTIAL_ID=1 bin/rails identity:revoke.
Revoked or expired tokens receive 401; out-of-scope permissions receive 403.
Credentials store only SHA-256 digests of random 256-bit tokens, never raw tokens.
Creation and revocation are recorded in IntegrationAuditEvent.

Existing application records are migrated into a locked legacy-unclaimed organization
for manual review, not granted to a newly created user.

**Still out of scope:** GitHub account sign-in/SSO and persistent user-side GitHub access. The GitHub OAuth flow in PR #3 is only used to prove installation ownership and associate an installation with an existing Deplograph organization. Short-lived installation tokens authorize per-repository reads. Without configured GitHub App credentials, only public repository inspection is available.
Additional hardening before public deployment includes TLS, provider OIDC, rate limits,
password recovery and scoped management UI.

A matching runtime image is partial evidence, not full deployment verification.
Immutable artifacts and OSV source preservation remain enforced.


## GitHub App connection (stacked PR #3)

This is an opt-in adapter. It is not enabled until a GitHub App has been registered
and its credentials configured. To register your own App, configure in GitHub:

- Setup URL: https://YOUR-HOST/github/installations/setup
- OAuth callback URL: https://YOUR-HOST/github/installations/callback
- Webhook URL: https://YOUR-HOST/api/v1/github/webhooks
- App repository permissions: **Contents: read**, **Metadata: read**
- Webhook events: installation, installation_repositories, push
- Keep "Request user authorization (OAuth) during installation" disabled when using
  the separate setup URL flow. Deplograph starts the OAuth authorization after setup.

Set GITHUB_APP_ID, GITHUB_APP_CLIENT_ID, GITHUB_APP_CLIENT_SECRET,
GITHUB_APP_PRIVATE_KEY, GITHUB_APP_CALLBACK_URL, GITHUB_APP_SLUG and
GITHUB_WEBHOOK_SECRET via your deployment secrets manager. The private key may be
a PEM value with literal newline characters or escaped newlines. Never commit
credentials to this repository.

1. Log in to Deplograph with an owner/admin account and open /github/installations.
2. Install the GitHub App, selecting only needed repositories.
3. GitHub redirects to the setup URL with installation_id.
4. Click Verify and link. Deplograph uses a one-time OAuth state, checks the
   authenticated GitHub user's installation list and independently checks the App
   installation and its permissions through a signed App JWT.
5. After successful verification, the installation belongs to one organization,
   and permitted repository grants are synchronized. Initial SPDX imports are
   queued for the selected repositories.
6. Later push and repository selection events can queue another import, and
   revoked/suspended/deleted permissions prevent further sync.

IMPORTANT: The setup URL installation_id is **not** authentication. User OAuth
credentials are discarded after installation verification. Short-lived installation
tokens are requested only when needed, with each SBOM import scoped to one repo ID.

GitHub SBOM export is asynchronous: generate-report responds with a report URL;
fetch-report returns 202 while processing or 302 to a temporary download when
ready. Deplograph saves pending request UUIDs, polls through Github::SyncRepositoryJob
and accepts only allowlisted HTTPS GitHub download hosts. The temporary URL never
receives the installation access token. Failed and pending imports remain visible.

A GitHub dependency graph SPDX report is an inventory of GitHub's dependency graph
at export time. **It is not build provenance**, does not prove a Git commit was
deployed, and must not be treated as verified runtime inventory. For that use OCI
artifacts, build attestations, CI-generated SBOMs, and runtime observations.

Current limitations: the prototype uses Rails' non-durable async Active Job adapter,
so outstanding jobs can be lost on a restart. Move to Solid Queue, implement
rate-limit backoff, and add credential-scoped job observability before production.
Only explicitly allowed GitHub download hosts are supported: unexpected redirects
fail closed. GitHub OAuth here verifies the installation, but user sign-in remains
the local Deplograph password/session flow.


## Ruby lockfile inventory & advisory history (stacked PR #4)

Deplograph can now parse a Ruby \`Gemfile.lock\` into CycloneDX components and
dependency edges. It is safe to test without registering a GitHub App:

    bin/rails test test/services/inventory/gemfile_lock_test.rb

To import a lockfile from an API client with a \`report\` credential:

    jq -n --arg repository "acme/ruby-demo" --rawfile lockfile Gemfile.lock \
      '{repository: $repository, lockfile: $lockfile}' |
      curl -H "Authorization: Bearer $DEPLOGRAPH_API_TOKEN" \
           -H "Content-Type: application/json" \
           --data-binary @- http://localhost:3000/api/v1/inventories/lockfile

The importer records a content-addressed artifact and immutable inventory
snapshot. GitHub App repository sync independently checks \`Gemfile.lock\`
with a repository-scoped installation token. If that manifest is absent, the
GitHub SPDX export continues separately.

**Coverage is partial.** A lockfile describes resolved Ruby dependencies
but says nothing about OS packages, container layers, or what is currently
running. The parser does not claim build provenance or an exact deployed
commit. A missing vulnerability match does not mean "safe" when scanning
is disabled, incomplete, stale or failed.

Scan history records trigger, provider, start/completion timestamps,
match counts and errors. When \`OSV_ENABLED=true\`, use this command from
a trusted scheduler to enqueue due scans (24-hour default, 200 per invocation):

    bin/rails inventory:rescan_due

This allows newly published advisories to affect **unchanged inventory**.
The repository does not configure a recurring production scheduler yet:
you must schedule this task and run a durable background queue before
production. A scan failure retains the last successful OSV evidence but
marks the current scan as failed, never as "no vulnerabilities".
OSV/CVE/GHSA alias normalization and broader advisory feeds remain future work.


## Environment drift comparison (stacked PR #5)

The first Drift Engine uses existing data from CI-declared deployments, release
artifacts, SBOM component versions and OSV results. It does **not** claim to
verify a complete production rollout.

With a scoped API credential containing \`read\` permission for both environments:

    curl -X POST http://localhost:3000/api/v1/drift/comparisons \
      -H "Authorization: Bearer $DEPLOGRAPH_API_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"repository":"acme/payments","baseline_environment":"staging","target_environment":"production","mode":"reported"}'

Read a comparison later via \`GET /api/v1/drift/comparisons/:id\`, or list
authorized history via \`GET /api/v1/drift/comparisons?repository=acme/payments\`.
Results preserve the release, artifact identity, evidence event and inventory
snapshot IDs that were used. A new comparison is a new historical record.

Current dimensions:

- \`release\`: logical release name from the latest deployment report.
- \`artifact\`: reported image digest or source artifact identity.
- \`dependencies\`: added, removed and version-changed package families from
  available per-artifact inventory snapshots.
- \`security\`: advisories observed only in one environment, shared findings,
  plus OSV scan timestamps and freshness.
- \`workloads\`: when \`mode=observed\`, the workloads actually seen by partial
  runtime observations, not an authoritative complete workload list.

\`mode=reported\` compares declarations and is **not** verified runtime state.
\`mode=observed\` uses latest observations by workload and always remains
partial evidence until real collector coverage semantics exist.
Missing SBOMs or unscanned advisories produce \`unknown\`; aged scans can
produce \`stale\`; incomplete scope produces \`partial\`. Known differences can
still be reported even when confidence is partial. The response never
represents \`unknown\` as \`same\`.

An SBOM only on a source lockfile is **not automatically assigned to a built
image**. Build provenance and image digest linkage must be verified in a later
increment. This avoids attributing source-only vulnerabilities to a deployed
image without evidence.

ENV variable **names-only drift** is now supported in PR #7. Keyed value fingerprints,
expected-difference policies, complete collector coverage and verified remediation
remain future work.


## ENV Names Drift (stacked PR #7)

Deplograph can now compare the **number and names** of environment variables
between staging, production or any other pair of environments **without
collecting their values**.

The collection API accepts strictly:
\`repository\`, \`environment\`, \`source\`, \`scope\`, \`workload\`, \`collection_id\`,
\`completeness\`, \`collected_at\` and \`keys\` (array of names only).
It rejects extra fields including \`values\`, duplicate keys, and any key
containing an equals sign or an embedded value.

- \`POST /api/v1/configuration_snapshots\`: upload names-only snapshot with
  provider-bound credentials. \`scope=declared\` requires \`report\`; \`scope=process\`
  requires \`observe\`.
- \`GET /api/v1/configuration_snapshots?repository=acme/payments&environment=staging\`:
  view snapshots and keys, with environment- and tenant-scoped \`read\` permission.
- \`POST /api/v1/configuration/drift\`: compare matching workload, scope and
  source, then persist result in existing DriftComparison history.
- \`GET /api/v1/drift/comparisons/:id\`: read that comparison later.

You can import synthetic declared inventories from
\`examples/scenarios/configuration-names/staging.json\` and \`production.json\`
using a scoped \`github_actions\` reporter token. Refresh their \`collected_at\`
timestamps when testing current-state comparisons.

Example comparison request:

    curl -X POST http://localhost:3000/api/v1/configuration/drift \
      -H "Authorization: Bearer $DEPLOGRAPH_API_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"repository":"acme/payments","baseline_environment":"staging","target_environment":"production","workload":"web","scope":"declared"}'

The result includes key counts, common names, only-in-baseline,
only-in-target, both snapshot IDs, collection timestamps and completeness.
An equal key count is **not** proof that two sets are equal. If one snapshot
is partial, absence of a key is not asserted, even when the known key
sets differ. Old snapshots return \`stale\` and non-comparable sources return
\`unknown\`.

The one-shot \`collectors/bin/env_keys_observe\` uses **only \`ENV.keys\`**
inside its *own* executing Ruby process and skips collector-specific
\`DEPLOGRAPH_*\` keys. It sends no values. Because this is the collector
process's environment, not evidence of the main app process's effective
state, it always reports \`completeness=partial\`. It must not be run in an
unrelated CronJob and interpreted as the app's ENV. Future runtime
instrumentation can report a directly observed process's exact key set.

ENV names themselves may contain sensitive architecture information.
Keep read permissions narrow. Value HMACs, explicit policies like
\`must_match/must_differ/ignore\`, and actual secret values are **not**
implemented here.


## ENV fingerprints and policies (stacked PR #8)

This opt-in extension to **names-only** configuration drift compares values
without transmitting or storing them in Deplograph. Instead, an explicitly
enabled collector computes **HMAC-SHA256** locally and uploads only 64-character
hexadecimal digests attached to a recently collected names-only snapshot.

The HMAC key is a separate high-entropy secret shared securely across the two
environments being compared. The key is **not** the Deplograph API bearer token,
is **never** sent to Deplograph and must have at least 32 random bytes. Store
it in a restricted-access file, not source control. Give the key a stable
non-secret ID such as \`rotation-2026-11\`. For a meaningful comparison,
both sides must use the **same secret and key ID**. Different IDs produce
\`unknown\`, not a claim of changed values. The backend does not possess
the key and cannot prove that a client used a correctly configured key.

HMAC message format:
\`JSON.generate(["deplograph-env-value-v1", repository, variable_name, value])\`.
This isolates fingerprints by repository and variable name. Do **not** replace
HMAC with plain SHA-256: low-entropy ENV values would be vulnerable to offline
dictionary attacks. HMAC still exposes equality to authorized comparisons and
to an attacker who steals the key. Use least-privilege collector credentials,
TLS, a secret manager and key rotation.

### Collector

The new opt-in script is \`ruby collectors/bin/env_fingerprints_observe\`.
It reads values **only in its own process**, calculates HMAC locally and
sends one names-only snapshot and one HMAC batch to Deplograph. It excludes
\`DEPLOGRAPH_*\` keys, including collector settings. Required client settings:

- \`DEPLOGRAPH_CONFIG_URL\`: URL ending in \`/api/v1/configuration_snapshots\`
- \`DEPLOGRAPH_TOKEN\`: provider-matching \`observe\` credential
- \`DEPLOGRAPH_REPOSITORY\`, \`DEPLOGRAPH_ENVIRONMENT\`, \`DEPLOGRAPH_WORKLOAD\`
- \`DEPLOGRAPH_COLLECTOR_SOURCE\`: e.g. \`docker_agent\`
- \`DEPLOGRAPH_HMAC_KEY_FILE\`: local path to raw random key bytes
- \`DEPLOGRAPH_HMAC_KEY_ID\`: non-secret rotation ID

If the script runs in an unrelated CronJob, the collected variables describe
the CronJob, **not** the Rails/Kamal process. The resulting snapshots remain
\`completeness=partial\`. For reliable application-level values, explicit
instrumentation inside the target process is needed. This collector must not
be mistaken for that instrumentation.

### API and policies

- \`POST /api/v1/configuration/fingerprints\`: submit one immutable batch for a
  snapshot collected within the last ten minutes. The server validates names
  and digest shapes but never sees plaintext values or the shared HMAC key.
- \`PUT /api/v1/configuration/policies\`: manage a per-repository,
  baseline/target environment, workload, scope and variable policy. Requires
  a \`manage\` credential scoped to **both environments**.
- \`GET /api/v1/configuration/policies\`: list scoped policies with \`read\`.
- \`POST /api/v1/configuration/fingerprints/drift\`: compare HMAC evidence with
  \`read\` on both environments and persist the result in DriftComparison
  history. No raw digests appear in the response.

Rules are \`must_match\` (default for keys without a rule),
\`must_differ\`, \`allowed_to_differ\`, and \`ignore\`. When a rule is violated,
the result identifies the variable name and reports \`value_relation=equal\` or
\`different\`, never the values. Rule changes are stored in
\`ConfigurationPolicyChange\` with the integration credential that made them.

A \`same\` fingerprint-drift result means **compliant with configured policies**,
not that every ENV value is identical. Distinct environment key sets and
unresolved fingerprints remain visible. Incomplete snapshots, unmatched key
IDs, unobserved variables and stale evidence cannot produce a verified
clean-state assertion. No runtime verification is claimed.

Fingerprint collection is sensitive even without plaintext. HMAC comparisons
can reveal whether a value has changed, and ENV names may expose architecture.
This MVP does not implement user-facing policy editing, KMS-backed key
distribution, key compromise detection, threshold alerts, or verified
collector attestation. Those belong to future PRs.


## Drift Dashboard & Findings (stacked PR #9)

A logged-in organization member can now open \`/drift\` to see recent
environment comparisons, filter by application, inspect reported versus
observed evidence, and run new reported/observed comparisons where the
necessary data exists. The \`/findings\` page presents actionable drift,
incomplete evidence, status, priority, assigned owner and the latest comparison.

### Finding lifecycle

Every new \`DriftComparison\` is inspected for actionable differences and
evidence gaps. A stable SHA-256 fingerprint identifies the same type of
problem across repeat comparisons for the same application, environment
pair and evidence mode. Repeated observations update \`last_seen_at\` and
the latest evidence pointer, but do not reset workflow status or owner.
The original evidence remains accessible in immutable comparison history.

Supported workflow states: \`open\`, \`acknowledged\`, \`investigating\`,
\`verification_pending\`, \`dismissed\`, \`resolved\`. Current operators
**cannot manually set \`resolved\`**. Deplograph requires a future
independent verification path proving that a remediation is running.
A new deployment report or an unverified observed digest does not qualify.
Dismissal requires an explanatory audit note and is not equivalent to
a security fix.

Findings retain the exact comparison ID, first/last seen timestamps,
category, severity, priority, owner and next action. The audit trail
records status changes, ownership changes, notes and priority/severity
reclassification. Findings may include a known difference even when
evidence confidence is partial. Unknown/stale data creates evidence-gap
findings, not false "healthy" statuses.

The initial priority classification is operational triage, not a CVSS
score. Advisories from unscored sources have \`severity=unknown\`;
operators can set a reviewed severity. A comparison status of \`same\`
for HMAC policies means policy compliance, not identical ENV values.
Expected/ignored HMAC differences do not become findings.

### Access control

- Browser \`/drift\`, \`/drift/comparisons/:id\`, \`/findings\`, \`/findings/:id\`
  require local login and an active membership of the selected organization.
- Owners/admins can update priority, severity, triage status, assignee,
  notes and next action. Members may triage and assign; viewers are read-only.
- The read-only \`GET /api/v1/findings\` and \`GET /api/v1/findings/:id\`
  endpoints require scoped \`read\` credentials. List filtering is performed
  at the SQL level using the credential's repository and environment grants
  before applying the 100-result limit. No raw HMACs or ENV values are returned.
- Dashboard and finding views use Rails auto-escaping and CSRF-protected
  forms. No public sign-up or unauthenticated access is introduced.

This PR only implements an operational browser dashboard and persisted
findings. It does **not** install a GitHub App, create live collectors,
verify a complete runtime rollout or add email/Slack alerting.

Run the full Minitest suite with \`bin/rails test\`, or the new UI/API
tests with \`bin/rails test test/integration/findings_dashboard_test.rb
test/integration/findings_api_test.rb\`. The frontend is server-rendered
Rails/ERB, with no new JavaScript dependencies.
