# Deplograph

**Know what runs where.** Rails 8.1 application for repository inspection, software bill of materials (SBOM) ingestion, dependency graphs, vulnerability matches, and environment-aware deployment reports.

This is a working MVP, not a production-certified vulnerability scanner.

## Stack

- Ruby 4.0.10 (single source of truth: .ruby-version)
- Rails 8.1.4.1 and PostgreSQL
- Minitest + WebMock for isolated tests
- Active Job using the async adapter for this prototype
- GitHub Actions CI, source SBOM generation and deployment reporting

## Local setup

Prerequisites: Ruby 4.0.10, Bundler and PostgreSQL.

1. Install gems with: bundle install
2. Set DATABASE_URL if your local PostgreSQL connection differs from the default.
3. Prepare DB: bin/rails db:prepare
4. Set ingestion token: export DEPLOGRAPH_INGEST_TOKEN="$(openssl rand -hex 32)"
5. Start web: bin/rails server
6. Open http://localhost:3000 and try the scenarios from examples/README.md.

The application does not automatically load .env.example. Export values or use a secret manager.

## Architecture

- Application - repository identity and inspected build metadata.
- Artifact - source commit, binary artifact or OCI image identity.
- InventorySnapshot - original SBOM JSON and SHA-256 hash, attached to a specific artifact.
- Component - a package with PURL; ComponentOccurrence - presence in a snapshot.
- DependencyEdge - relationships from CycloneDX or SPDX.
- Environment - production, staging, sandbox, test, preview or development, with optional TTL.
- Deployment - CI report with immutable external deployment ID. A reported deployment is NOT independent evidence that the image is running.
- VulnerabilityMatch - OSV querybatch result for a versioned package occurrence.

Ingestion does not execute user-supplied SBOM content, Dockerfiles or manifest files.

## Endpoints

All write endpoints require a configured DEPLOGRAPH_INGEST_TOKEN via Authorization: Bearer TOKEN.

- POST /api/v1/inventories - CycloneDX JSON or SPDX 2.x JSON for an artifact.
- POST /api/v1/deployments - image digest or commit SHA, provider, environment, deployment ID and time.
- POST /api/v1/environment_events - preview creation/destruction and expiry.
- POST /api/v1/repositories/inspect - read-only GitHub inspection for allowlisted files and repository metadata. Configure GITHUB_TOKEN for private repos.
- GET /up - liveness check.
- GET / - simple inventory dashboard (no login in this MVP).

Find complete runnable JSON examples, a synthetic artifact relationship graph, and a localhost mock GitHub API in examples/.

## GitHub Actions

CI runs the Rails test suite with PostgreSQL 16 on every PR and every push to main.

The SBOM workflow runs on pushes to main or manually. It uses Syft via anchore/sbom-action to produce CycloneDX JSON, retained as a workflow artifact. When the repository variable DEPLOGRAPH_API_URL and the GitHub Actions secret DEPLOGRAPH_INGEST_TOKEN are configured, it POSTs inventory to Deplograph.

The deployment-report workflow provides an explicit workflow_dispatch action to report an existing deployment for production, staging, sandbox, test or preview. This workflow does not deploy anything. In GitHub Settings > Environments, configure protection rules for sensitive environment names.

The GitHub repository inspector uses read-only REST API requests and only fetches allowlisted build manifest paths. The newer asynchronous GitHub SBOM generate-report / fetch-report endpoints can be added later as an independent collector.

## Matching with OSV

Set OSV_ENABLED=true to queue matching for imported snapshots. The matcher requests only versioned PURLs through the official OSV querybatch API and handles pagination. An upstream HTTP failure results in a failed match status, never an incorrect "safe" result.

Matching is not exploitability analysis. No claim is made that a component is exploitable in production merely because an advisory matches the version.

## Boundaries / follow-up work

- This MVP does not independently verify running images on Kubernetes/Kamal/AWS.
- No deployed SaaS instance, public auth, tenancy, billing or secrets store yet.
- The async job backend is not durable across process restarts. Replace it with Solid Queue and recurring retry policies before production.
- Supports CycloneDX component/dependency basics and SPDX 2.x PURLs. SPDX 3.x and full schema validation are future work.
- No GitHub App installation flow or production-grade OCI image scanner yet.
- No actual Slack notifications are sent. Slack can be integrated after alert rules and tenant isolation.
- Do not make the dashboard public: there is no user sign-in yet.
- Before production use, generate and commit Gemfile.lock, pin GitHub Actions to reviewed SHAs, set rate limits, audit logs and least-privilege secrets.

## Tests

    bundle install
    RAILS_ENV=test bin/rails db:prepare
    bin/rails test

The tests use WebMock and synthetic SBOMs. They do not contact GitHub or OSV. Root Dockerfile is a baseline prototype, not an audited hardened production image.
