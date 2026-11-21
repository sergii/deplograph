module Configuration
  class PolicyRecorder
    def call(application:, baseline_environment:, target_environment:, workload:,
             scope:, name:, rule:, credential:)
      unless ConfigurationPolicy::RULES.include?(rule)
        raise ArgumentError, "Unsupported configuration policy"
      end

      ConfigurationPolicy.transaction do
        policy = application.configuration_policies.find_or_initialize_by(
          baseline_environment: baseline_environment,
          target_environment: target_environment,
          workload: workload, scope: scope, name: name
        )
        policy.lock! if policy.persisted?
        old_rule = policy.rule
        if policy.new_record? || old_rule != rule
          policy.update!(rule: rule)
          policy.configuration_policy_changes.create!(
            integration_credential: credential,
            previous_rule: old_rule, new_rule: rule
          )
        end
        policy
      end
    end
  end
end
