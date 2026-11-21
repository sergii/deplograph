class User < ApplicationRecord
  has_secure_password

  has_many :runtime_attestors, foreign_key: :approved_by_id, dependent: :restrict_with_error
  has_many :remediation_attempts, foreign_key: :created_by_id, dependent: :restrict_with_error
  has_many :finding_verification_checks, foreign_key: :requested_by_id, dependent: :nullify
  has_many :memberships, dependent: :destroy
  has_many :organizations, through: :memberships

  before_validation :normalize_email

  validates :password, length: { minimum: 12 }, if: -> { password.present? }

  validates :email, presence: true, uniqueness: { case_sensitive: false },
    format: { with: URI::MailTo::EMAIL_REGEXP }

  private

  def normalize_email
    self.email = email.to_s.strip.downcase
  end
end
