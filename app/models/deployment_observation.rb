class DeploymentObservation < ApplicationRecord
  belongs_to :environment
  belongs_to :deployment, optional: true
  belongs_to :artifact, optional: true

  validates :source, :event_id, :workload, :image_digest, :observed_at, presence: true
  validates :image_digest, format: { with: /\Asha256:[a-f0-9]{64}\z/ }
  validates :event_id, uniqueness: { scope: %i[environment_id source] }
end
