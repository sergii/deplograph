class Application < ApplicationRecord
  has_many :environments, dependent: :destroy
  has_many :artifacts, dependent: :destroy
  has_many :source_revisions, dependent: :destroy
  has_many :releases, dependent: :destroy

  validates :name, :repository_full_name, presence: true
  validates :repository_full_name, uniqueness: true
end
