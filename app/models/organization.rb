class Organization < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :applications, dependent: :destroy
  has_many :integration_credentials, dependent: :destroy
  has_many :integration_audit_events, dependent: :destroy
  has_many :github_installations, dependent: :nullify

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
end
