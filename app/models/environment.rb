class Environment < ApplicationRecord
  belongs_to :application
  has_many :deployments, dependent: :destroy
  has_many :deployment_events, dependent: :destroy
  has_many :deployment_observations, dependent: :destroy

  validates :name, presence: true
  validates :kind, inclusion: { in: %w[production staging sandbox test preview development other] }
  validates :state, inclusion: { in: %w[active destroyed] }
end
