class RemediationAttempt < ApplicationRecord
  STATUSES = %w[planned reported_applied cancelled].freeze

  belongs_to :drift_finding
  belongs_to :created_by, class_name: "User"
  belongs_to :release, optional: true
  belongs_to :deployment, optional: true
  belongs_to :vulnerability_scan_run, optional: true
  has_many :finding_verification_checks, dependent: :nullify

  validates :status, inclusion: { in: STATUSES }
  validates :description, presence: true, length: { maximum: 3_000 }
  validates :reference_url, length: { maximum: 2_048 }, allow_nil: true
  validate :applied_requires_evidence
  validate :same_tenant_evidence
  validate :safe_reference_url

  private

  def applied_requires_evidence
    if status == "reported_applied" && deployment.nil? && vulnerability_scan_run.nil?
      errors.add(:status, "requires a linked deployment or advisory scan")
    end
  end

  def same_tenant_evidence
    return unless drift_finding

    unless Membership.exists?(organization_id: drift_finding.organization_id, user_id: created_by_id)
      errors.add(:created_by, "must be a member of the finding organization")
    end
    if release && release.application_id != drift_finding.application_id
      errors.add(:release, "must belong to the finding application")
    end
    if deployment
      unless deployment.environment.application_id == drift_finding.application_id &&
             [drift_finding.baseline_environment_id, drift_finding.target_environment_id].include?(
               deployment.environment_id
             )
        errors.add(:deployment, "must belong to a compared environment of the finding")
      end
    end
    if release && deployment && deployment.release_id != release.id
      errors.add(:release, "must match the selected deployment release")
    end
    if vulnerability_scan_run
      snapshot = vulnerability_scan_run.inventory_snapshot
      if snapshot.artifact.application_id != drift_finding.application_id
        errors.add(:vulnerability_scan_run, "must belong to the finding application")
      end
      if deployment && snapshot.artifact_id != deployment.artifact_id
        errors.add(:vulnerability_scan_run, "must describe the selected deployment artifact")
      end
    end
  end

  def safe_reference_url
    return if reference_url.blank?

    uri = URI.parse(reference_url)
    return if uri.scheme == "https" && uri.host.present? &&
              uri.userinfo.nil? && uri.fragment.nil?

    errors.add(:reference_url, "must be a valid HTTPS URL without embedded credentials")
  rescue URI::InvalidURIError
    errors.add(:reference_url, "must be a valid HTTPS URL")
  end
end
