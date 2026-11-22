# Cross-provider deployment simulation lab

Synthetic application lifecycle without external GitHub, Kamal or Kubernetes credentials.

1. GitHub Actions builds two releases and reports production deployment A.
2. Kamal reports the same deployment A with a different event ID and source.
3. Kubernetes independently observes production running artifact A.
4. Staging reports and observes a fixed image B.
5. A synthetic advisory affects only image A.
6. API summary must say production has the match and staging has no known matches.
7. Duplicate events remain idempotent; conflicting IDs return 409.
8. Multiple workloads and out-of-order observations must not become multiple deployments.

Run: bin/rails test test/integration/release_lifecycle_test.rb

Evidence in fixtures is simulated, not a claim about running software.
