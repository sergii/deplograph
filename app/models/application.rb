class Application < ApplicationRecord
  belongs_to :organization
  has_many :drift_findings, dependent: :destroy
  has_many :configuration_policies, dependent: :destroy
  has_many :drift_comparisons, dependent: :destroy
  has_many :environments, dependent: :destroy
  has_many :artifacts, dependent: :destroy
  has_many :source_revisions, dependent: :destroy
  has_many :releases, dependent: :destroy

  validates :name, :repository_full_name, presence: true
  validates :repository_full_name, uniqueness: { scope: :organization_id }
end
