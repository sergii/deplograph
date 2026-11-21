class GithubWebhookDelivery < ApplicationRecord
  validates :delivery_id, :event, :payload_sha256, :received_at, presence: true
  validates :delivery_id, uniqueness: true
end
