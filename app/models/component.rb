class Component < ApplicationRecord
  has_many :component_occurrences, dependent: :restrict_with_error
  validates :purl, presence: true, uniqueness: true
end
