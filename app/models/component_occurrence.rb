class ComponentOccurrence < ApplicationRecord
  belongs_to :inventory_snapshot
  belongs_to :component
  has_many :vulnerability_matches, dependent: :destroy
end
