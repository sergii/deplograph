class SourceRevision < ApplicationRecord
  belongs_to :application
  has_many :builds, dependent: :destroy
  has_many :releases, dependent: :nullify

  validates :commit_sha, format: { with: /\A[a-f0-9]{40}\z/ }
  validates :commit_sha, uniqueness: { scope: :application_id }
end
