class InventorySnapshot < ApplicationRecord
  belongs_to :artifact
  has_many :vulnerability_scan_runs, dependent: :destroy
  has_many :dependency_edges, dependent: :destroy
  has_many :vulnerability_matches, dependent: :destroy
  has_many :component_occurrences, dependent: :destroy

  validates :coverage_status, inclusion: { in: %w[complete partial unknown] }
  validates :format, inclusion: { in: %w[cyclonedx spdx] }
  validates :sha256, uniqueness: { scope: :artifact_id }
end
