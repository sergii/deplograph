class Artifact < ApplicationRecord
  belongs_to :application
  has_many :inventory_snapshots, dependent: :destroy
  has_many :deployments, dependent: :restrict_with_error
  has_many :release_artifacts, dependent: :destroy
  has_many :build_artifacts, dependent: :destroy
  has_many :deployment_observations, dependent: :nullify

  validates :identifier, :kind, presence: true
  validates :identifier, uniqueness: { scope: :application_id }
  validates :kind, inclusion: { in: %w[source image binary] }
  validate :immutable_identity, on: :update

  private

  def immutable_identity
    %i[kind image_digest commit_sha].each do |field|
      next unless will_save_change_to_attribute?(field)

      previous, current = attribute_change_to_be_saved(field)
      next if previous.blank? && current.present?

      errors.add(field, "is immutable once set")
    end
  end
end
