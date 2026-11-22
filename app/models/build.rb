class Build < ApplicationRecord
  belongs_to :source_revision
  has_many :build_artifacts, dependent: :destroy
  has_many :artifacts, through: :build_artifacts

  validates :provider, :external_id, presence: true
end
