# frozen_string_literal: true

module ::DiscourseInsights
  class ReportsController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    include DiscourseInsights::AccessControl

    before_action :ensure_logged_in
    before_action :ensure_allowed
    before_action :ensure_data_explorer

    def index
      list = report_list
      render json: { reports: list.user_reports.map { |q| serialize_query(q, list) } }
    end

    def run
      query_id = params[:id].to_i
      query = DiscourseDataExplorer::Query.find(query_id)
      raise Discourse::NotFound if query.hidden || !guardian.user_can_access_query?(query)

      RateLimiter.new(
        current_user,
        "insights-run-report",
        30,
        1.minute,
        apply_limit_to_staff: true,
      ).performed!

      runner = InsightsReportRunner.new(query, current_user, params.to_unsafe_h)
      render json: runner.run
    rescue StandardError => e
      if e.is_a?(Discourse::NotFound) || e.is_a?(RateLimiter::LimitExceeded) ||
           e.is_a?(ActiveRecord::RecordNotFound)
        raise e
      end
      render json: { error: e.message }, status: :unprocessable_entity
    end

    def add
      query_id = params[:query_id].to_i
      query = DiscourseDataExplorer::Query.find(query_id)
      raise Discourse::NotFound if query.hidden || !guardian.user_can_access_query?(query)

      report_list.add_report(query_id)
      render json: { success: true }
    end

    def remove
      report_list.remove_report(params[:id].to_i)
      render json: { success: true }
    end

    def available
      list = report_list
      pinned = list.user_report_ids

      render json: {
               queries: list.available_reports.map do |q| serialize_query(q, list, pinned:) end,
             }
    end

    private

    def report_list
      @report_list ||= InsightsReportList.new(current_user, guardian)
    end

    def serialize_query(query, list, pinned: nil)
      result = {
        id: query.id,
        name: query.name,
        description: query.description,
        insights: list.seeded_query_ids.include?(query.id),
      }
      result[:pinned] = pinned.include?(query.id) if pinned
      result
    end

    def ensure_data_explorer
      unless defined?(DiscourseDataExplorer) && SiteSetting.data_explorer_enabled
        raise Discourse::NotFound
      end
    end
  end
end
