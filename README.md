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
- POST /api/v1/repositories/inspect - read-only GitHub inspection for allowlisted files and repository metadata. Configure GITHUB_TOKEN for private repos.
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

The GitHub repository inspector uses read-only REST API requests and only fetches allowlisted build manifest paths. The newer asynchronous GitHub SBOM generate-report / fetch-report endpoints can be added later as an independent collector.

## Matching with OSV

Set OSV_ENABLED=true to queue matching for imported snapshots. The matcher requests only versioned PURLs through the official OSV querybatch API and handles pagination. An upstream HTTP failure results in a failed match status, never an incorrect "safe" result.

Matching is not exploitability analysis. No claim is made that a component is exploitable in production merely because an advisory matches the version.

## Boundaries / follow-up work

- This MVP does not independently verify running images on Kubernetes/Kamal/AWS.
- No hosted SaaS instance, OAuth, billing or external secrets store yet.
- The async job backend is not durable across process restarts. Replace it with Solid Queue and recurring retry policies before production.
- Supports CycloneDX component/dependency basics and SPDX 2.x PURLs. SPDX 3.x and full schema validation are future work.
- Local user sign-in and API tenant scoping are implemented. GitHub App installation onboarding and short-lived installation tokens remain next.
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

**Still out of scope:** GitHub OAuth and actual GitHub App installation token flow.
Signed installation webhooks are recorded but are not yet joined to an organization.
The server-side GitHub repository inspector continues to use a configured GitHub token.
Do not treat it as a complete per-installation GitHub permission boundary.
Additional hardening before public deployment includes TLS, provider OIDC, rate limits,
password recovery and scoped management UI.

A matching runtime image is partial evidence, not full deployment verification.
Immutable artifacts and OSV source preservation remain enforced.
