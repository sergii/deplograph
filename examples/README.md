# Synthetic example scenarios

- sample_cyclonedx.json: CycloneDX components and dependencies.
- sample_spdx.json: SPDX 2.3 packages and DEPENDS_ON relationship.
- sample_deployment.json: CI-reported deployment with a fake OCI digest.
- sample_environment_created.json: preview environment lifecycle with TTL.
- sample_artifact_graph.json: source -> commit -> image -> environment graph.
- source_app/: fixture-only Dockerfile, Ruby version and intentionally incomplete lockfile.
- mock_github_server.rb: localhost GitHub API emulator for manual inspection.

Start Rails and set DEPLOGRAPH_INGEST_TOKEN.

Import the SBOM using the API:

    jq -n --slurpfile sbom examples/sample_cyclonedx.json \
      '{repository:"acme/rails-app",artifact_identifier:"git:example",
        format:"cyclonedx",sbom:$sbom[0]}' \
      | curl -fsS -X POST http://localhost:3000/api/v1/inventories \
          -H "Authorization: Bearer $DEPLOGRAPH_INGEST_TOKEN" \
          -H "Content-Type: application/json" --data-binary @-

Report a deployment:

    curl -fsS -X POST http://localhost:3000/api/v1/deployments \
      -H "Authorization: Bearer $DEPLOGRAPH_INGEST_TOKEN" \
      -H "Content-Type: application/json" \
      --data-binary @examples/sample_deployment.json

Create a preview environment:

    curl -fsS -X POST http://localhost:3000/api/v1/environment_events \
      -H "Authorization: Bearer $DEPLOGRAPH_INGEST_TOKEN" \
      -H "Content-Type: application/json" \
      --data-binary @examples/sample_environment_created.json

Start the mock GitHub API:

    bundle exec ruby examples/mock_github_server.rb

Then in Rails console:

    client = Github::ApiClient.new(token: nil, base_url: "http://127.0.0.1:4567")
    Github::RepositoryInspector.new(client: client).call("acme/rails-app")

The emulator binds to localhost only and is not a production API.
