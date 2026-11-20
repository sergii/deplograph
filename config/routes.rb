Rails.application.routes.draw do
  get "/up", to: proc { [200, { "content-type" => "text/plain" }, ["ok"]] }
  root "dashboard#index"

  namespace :api do
    namespace :v1 do
      post "inventories", to: "inventories#create"
      post "deployments", to: "deployments#create"
      post "environment_events", to: "environment_events#create"
      post "repositories/inspect", to: "repositories#inspect"
    end
  end
end
