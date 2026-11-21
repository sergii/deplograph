class GithubRepositoryGrant < ApplicationRecord
  belongs_to :github_installation

  validates :github_repository_id, presence: true, uniqueness: { scope: :github_installation_id }
  validates :full_name, presence: true
end
