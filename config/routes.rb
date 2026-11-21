Rails.application.routes.draw do
  get "/up", to: proc { [200, { "content-type" => "text/plain" }, ["ok"]] }
  root "dashboard#index"
  get "/login", to: "sessions#new", as: :login
  post "/login", to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout
  post "/organizations/:id/select", to: "organizations#select", as: :select_organization
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
