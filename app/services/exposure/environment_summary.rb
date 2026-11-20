module Exposure
  class EnvironmentSummary
    MAX_FRESHNESS = 1.hour

    def call(application)
      application.environments.order(:name).map do |environment|
        latest_report = environment.deployments.order(deployed_at: :desc).first
        observations = environment.deployment_observations
          .order(observed_at: :desc, id: :desc).to_a.uniq(&:workload)

        {
          name: environment.name, kind: environment.kind,
          state: environment.state, expires_at: environment.expires_at,
          reported: latest_report && {
            deployment_id: latest_report.external_id,
            artifact: latest_report.artifact.identifier,
            release: latest_report.release&.name,
            reporting_sources: latest_report.deployment_events
              .where(event_type: "deployment.reported").distinct.pluck(:source).sort,
            status: latest_report.status,
            deployed_at: latest_report.deployed_at
          },
          observed: observations.map { |obs| represent(obs) }
        }
      end
    end

    private

    def represent(observation)
      artifact = observation.artifact
      snapshot = artifact&.inventory_snapshots&.order(created_at: :desc)&.first
      ids = snapshot ? snapshot.vulnerability_matches
        .includes(:vulnerability).map { |match| match.vulnerability.identifier }.uniq.sort : []
      {
        workload: observation.workload,
        source: observation.source,
        event_id: observation.event_id,
        image_digest: observation.image_digest,
        observed_at: observation.observed_at,
        fresh: observation.observed_at >= Time.current - MAX_FRESHNESS,
        inventory_status: snapshot&.match_status || "missing",
        vulnerability_ids: ids
      }
    end
  end
end
