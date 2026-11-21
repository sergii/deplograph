Rails.application.routes.draw do
  get "/up", to: proc { [200, { "content-type" => "text/plain" }, ["ok"]] }
  root "dashboard#index"
  get "/login", to: "sessions#new", as: :login
  post "/login", to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout
  post "/organizations/:id/select", to: "organizations#select", as: :select_organization
  get "/api/docs", to: "docs#index"
  get "/github/installations", to: "github/installations#index", as: :github_installations
  get "/github/installations/setup", to: "github/installations#setup", as: :github_installation_setup
  post "/github/installations/authorize", to: "github/installations#authorize", as: :authorize_github_installation
  get "/github/installations/callback", to: "github/installations#callback", as: :github_installation_callback
  post "/github/installations/:installation_id/sync", to: "github/installations#sync", as: :sync_github_installation
  post "/github/installations/:installation_id/repositories/:repository_id/import",
    to: "github/imports#create", as: :import_github_repository


  namespace :api do
    namespace :v1 do
      post "inventories", to: "inventories#create"
      post "inventories/lockfile", to: "inventories#import_lockfile"
      post "deployments", to: "deployments#create"
      post "environment_events", to: "environment_events#create"
      post "repositories/inspect", to: "repositories#inspect"
      resources :releases, only: %i[index create]
      resources :environments, only: :index
      resources :drift_comparisons, only: %i[index create show], path: "drift/comparisons"
      post "integration_events", to: "integration_events#create"
      post "github/webhooks", to: "github_webhooks#create"
    end
  end
end
