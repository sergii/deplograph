class InventorySnapshot < ApplicationRecord
  belongs_to :artifact
  has_many :component_occurrences, dependent: :destroy
  has_many :dependency_edges, dependent: :destroy
  has_many :vulnerability_matches, dependent: :destroy

  validates :format, inclusion: { in: %w[cyclonedx spdx] }
  validates :sha256, uniqueness: { scope: :artifact_id }
end
