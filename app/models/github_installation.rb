class GithubInstallation < ApplicationRecord
  belongs_to :organization, optional: true
  belongs_to :linked_by, class_name: "User", optional: true
  has_many :github_repository_grants, dependent: :destroy

  validates :installation_id, presence: true, uniqueness: true
  validates :account_login, presence: true
  validates :state, inclusion: { in: %w[active suspended deleted] }
end
