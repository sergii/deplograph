# Deplograph MVP pilot runbook

Status: candidate workflow, not a completed production deployment.

## Scope

The first experiment is a private, access-restricted Deplograph instance with
one Ruby/Rails repository, read-only GitHub integration, a source inventory,
a real OSV advisory scan and clear evidence labels. Do **not** enable signed
Kubernetes attestors, automatic runtime resolution or public self-service.

The one-off public proof runs as GitHub Actions
`.github/workflows/mvp-live-pilot.yml`: it imports the real public
`discourse/discourse` lockfile through the authenticated report API and
queries `https://api.osv.dev/v1/querybatch`. No GitHub App, cloud host,
or write access to that repository is needed for this CI smoke.

## Durable jobs

The persistent pilot runs production Rails with two PostgreSQL databases:
one for application records, one for Solid Queue. This avoids an in-process
`:async` queue losing scheduled GitHub import polls or OSV scans after restart.

Required secret environment variables (configure out of band):

- `DATABASE_URL`: primary application PostgreSQL DSN
- `QUEUE_DATABASE_URL`: **different** PostgreSQL database DSN for Solid Queue
- `SECRET_KEY_BASE`: long random Rails signing secret
- `RAILS_ENV=production`

Use different database **names** even if both databases run on the same
PostgreSQL server. No fixed database passwords belong in Git. Provision
databases/roles and TLS separately with the hosting provider.

Initialize both schemas using `bin/rails db:prepare`, then run web and worker
as separate supervised processes:

```sh
bin/rails server -b 127.0.0.1 -p 3000
bundle exec ruby bin/jobs start
```

The worker must be restarted independently and monitored. The config file
`config/queue.yml` controls polling/concurrency. No web process needs to
process background jobs itself. A production-like smoke is provided by
`.github/workflows/queue-production-smoke.yml`.

## Real GitHub App installation

Provision a staging-only GitHub App with repository
`Contents: read` / `Metadata: read` permissions and the setup,
callback and webhook URLs documented in the main README. Add App credentials
and webhook secret from a secret manager, not from an issue or committed file.

Use an owner/admin login, authorize an installation with access to **one
selected repository**, and inspect the resulting grants at
`/github/installations`. `Queue repository inventory` now enqueues work;
you should see an import status, with no request waiting on GitHub report
polling. A stale pending state or an import failure must remain visible.

The source lockfile and GitHub dependency graph SBOM are independent pieces
of source evidence. Neither proves which release, image or container is
running on a Kubernetes or Kamal host.

## Live advisory scan

For a **controlled pilot only**, set `OSV_ENABLED=true` in web and worker.
New source inventory enqueues matching jobs. Run
`bin/rails inventory:rescan_due` periodically, using the appropriate
scheduler. If OSV is unavailable, mark the scan `failed`; a failed scan or
missing SBOM is not a zero-vulnerability guarantee.

## Product acceptance

One developer, without coaching, should be able to:

1. Connect a single repository and see permitted scope.
2. Watch the inventory status move through pending/completed/failed.
3. Inspect package/version inventory and **known** matched advisories.
4. Register a deployment *report* and optionally compare staging to
   production, with `unknown`/partial evidence when provenance is missing.
5. Explain which information is reported source inventory, reported
   deployment or observed runtime. Confirm no secrets are displayed.

Record time-to-first-inventory, time-to-first-actionable-finding,
source/scan failures and the top three confusing UI states. Only after
that test should the next user-facing improvement be prioritized.

## Deferred

- Public multi-tenant SaaS rollout and signup.
- Real production Kubernetes credentials or signing private keys.
- Signed attestation and automatic `resolved` from stacked PR #11-#13.
- Additional security scanners, alerting channels and exotic provenance.

PR #15 is stacked on PR #5 and does not merge or deploy any branch. Existing
PR #6-#13 should be reviewed separately. Main integration remains a manual
owner decision.
