# frozen_string_literal: true

DiscourseInsights::Engine.routes.draw do
  get "/health" => "health#show"
  post "/ai/generate" => "ai#generate"
  get "/live" => "live#show"
  get "/reports" => "reports#index"
  get "/reports/available" => "reports#available"
  get "/reports/:id/run" => "reports#run"
  post "/reports" => "reports#add"
  put "/reports/reorder" => "reports#reorder"
  put "/reports/save" => "reports#save"
  delete "/reports/:id" => "reports#remove"
  post "/feedback" => "feedback#create"
end

Discourse::Application.routes.draw do
  get "insights" => "discourse_insights/page#index"
  get "insights/reports" => "discourse_insights/page#index", :constraints => { format: "html" }
  mount ::DiscourseInsights::Engine, at: "insights"
end
