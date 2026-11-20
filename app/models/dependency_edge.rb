class DependencyEdge < ApplicationRecord
  belongs_to :inventory_snapshot
  belongs_to :from_occurrence, class_name: "ComponentOccurrence"
  belongs_to :to_occurrence, class_name: "ComponentOccurrence"
end
