class GithubInstallation < ApplicationRecord
  has_many :github_repository_grants, dependent: :destroy

  validates :installation_id, presence: true, uniqueness: true
  validates :account_login, presence: true
  validates :state, inclusion: { in: %w[active suspended deleted] }
end
