require "digest"
require "securerandom"

class IntegrationCredential < ApplicationRecord
  PROVIDERS = %w[api ci github_actions kamal kubernetes kamal_agent docker_agent aws_ecs].freeze
  PERMISSIONS = %w[read report observe manage].freeze
  TOKEN_PATTERN = /\Adpl_([0-9a-f]{16})_([0-9a-f]{64})\z/

  belongs_to :organization
  has_many :runtime_attestors, dependent: :destroy
  has_many :integration_audit_events, dependent: :destroy

  validates :name, presence: true
  validates :provider, inclusion: { in: PROVIDERS }
  validates :token_prefix, :token_digest, presence: true, uniqueness: true
  validate :valid_scopes

  def self.issue!(organization:, name:, provider:, permissions:, repository_scopes: [],
                  environment_scopes: [], expires_at: nil)
    prefix = SecureRandom.hex(8)
    token = "dpl_#{prefix}_#{SecureRandom.hex(32)}"
    credential = create!(
      organization: organization, name: name, provider: provider,
      token_prefix: prefix, token_digest: Digest::SHA256.hexdigest(token),
      permissions: permissions, repository_scopes: repository_scopes,
      environment_scopes: environment_scopes, expires_at: expires_at
    )
    credential.integration_audit_events.create!(organization: organization, action: "issued")
    [credential, token]
  end

  def self.authenticate(bearer)
    match = bearer.to_s.match(/\ABearer (dpl_[0-9a-f]{16}_[0-9a-f]{64})\z/)
    return nil unless match

    token = match[1]
    prefix = token.match(TOKEN_PATTERN)[1]
    credential = find_by(token_prefix: prefix)
    return nil unless credential&.active?

    digest = Digest::SHA256.hexdigest(token)
    return nil unless ActiveSupport::SecurityUtils.secure_compare(digest, credential.token_digest)

    credential
  end

  def active?
    revoked_at.nil? && (expires_at.nil? || expires_at.future?)
  end

  def permits?(permission:, repository: nil, environment: nil, provider: nil)
    return false unless active? && permissions.include?(permission)
    return false if provider.present? && self.provider != provider
    return false if repository_scopes.any? && (repository.nil? || !repository_scopes.include?(repository))
    return false if environment_scopes.any? && (environment.nil? || !environment_scopes.include?(environment))

    true
  end

  def revoke!
    with_lock do
      return if revoked_at.present?

      update!(revoked_at: Time.current)
      integration_audit_events.create!(organization: organization, action: "revoked")
    end
  end

  private

  def valid_scopes
    unless permissions.is_a?(Array) && permissions.present? &&
           permissions.all? { |permission| PERMISSIONS.include?(permission) } &&
           permissions.uniq == permissions
      errors.add(:permissions, "must be a nonempty set of supported permissions")
    end

    {
      repository_scopes: /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/,
      environment_scopes: /\A[A-Za-z0-9_.-]{1,120}\z/
    }.each do |attribute, pattern|
      value = public_send(attribute)
      unless value.is_a?(Array) && value.uniq == value &&
             value.all? { |entry| entry.is_a?(String) && entry.match?(pattern) }
        errors.add(attribute, "must be an array of valid, unique names")
      end
    end

    if permissions.is_a?(Array) && permissions.include?("observe") &&
       !Integrations::DeploymentEventIngestor::OBSERVERS.include?(provider)
      errors.add(:provider, "does not support runtime observations")
    end
  end
end
