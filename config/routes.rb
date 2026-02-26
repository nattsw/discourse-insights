# frozen_string_literal: true

DiscourseInsights::Engine.routes.draw do
  get "/health" => "health#show"
  post "/ai/generate" => "ai#generate"
  get "/reports" => "reports#index"
  get "/reports/available" => "reports#available"
  get "/reports/:id/run" => "reports#run"
  post "/reports" => "reports#add"
  delete "/reports/:id" => "reports#remove"
end

Discourse::Application.routes.draw do
  get "insights" => "discourse_insights/page#index"
  mount ::DiscourseInsights::Engine, at: "insights"
end
