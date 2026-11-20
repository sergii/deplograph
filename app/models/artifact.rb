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
end
