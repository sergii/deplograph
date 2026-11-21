class DocsController < ApplicationController
  def index
    return head :not_found unless Rails.env.development? || Rails.env.test?
  end
end
