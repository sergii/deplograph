class DeploymentEvent < ApplicationRecord
  belongs_to :environment
  belongs_to :deployment, optional: true

  validates :source, :event_id, :event_type, :occurred_at, presence: true
  validates :event_id, uniqueness: { scope: %i[environment_id source] }
end
