Rails.application.routes.draw do
  get "/up", to: proc { [200, { "content-type" => "text/plain" }, ["ok"]] }
  root "dashboard#index"
  get "/api/docs", to: "docs#index"

  namespace :api do
    namespace :v1 do
      post "inventories", to: "inventories#create"
      post "deployments", to: "deployments#create"
      post "environment_events", to: "environment_events#create"
      post "repositories/inspect", to: "repositories#inspect"
      resources :releases, only: %i[index create]
      resources :environments, only: :index
      post "integration_events", to: "integration_events#create"
      post "github/webhooks", to: "github_webhooks#create"
    end
  end
end
