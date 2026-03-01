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
      render json: { reports: list.user_reports.map { |r| serialize_report(r, list) } }
    end

    def run
      query = report_list.find_accessible_query!(params[:id].to_i)

      RateLimiter.new(
        current_user,
        "insights-run-report",
        30,
        1.minute,
        apply_limit_to_staff: true,
      ).performed!

      permitted_keys = query.params.map(&:identifier)
      query_params = params.permit(*permitted_keys).to_h
      runner = InsightsReportRunner.new(query, current_user, query_params)
      render json: runner.run
    rescue StandardError => e
      if e.is_a?(Discourse::NotFound) || e.is_a?(RateLimiter::LimitExceeded) ||
           e.is_a?(ActiveRecord::RecordNotFound)
        raise e
      end
      render json: { error: e.message }, status: :unprocessable_entity
    end

    def add
      query = report_list.find_accessible_query!(params[:query_id].to_i)
      report_list.add_report(query.id)
      render json: { success: true }
    end

    def remove
      report_list.remove_report(params[:id].to_i)
      render json: { success: true }
    end

    def reorder
      ids = params[:report_ids]&.map(&:to_i)
      raise Discourse::InvalidParameters.new(:report_ids) if ids.blank?
      report_list.reorder(ids)
      render json: { success: true }
    end

    def save
      entries = params[:reports]
      raise Discourse::InvalidParameters.new(:reports) if !entries.is_a?(Array) || entries.blank?

      parsed =
        entries.map do |entry|
          e = entry.permit(:query_id, params: {}).to_h.deep_symbolize_keys
          { query_id: e[:query_id], params: e[:params] }
        end

      report_list.save_all(parsed)
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

    def serialize_report(report, list)
      {
        id: report[:query].id,
        name: report[:query].name,
        description: report[:query].description,
        insights: list.seeded_query_ids.include?(report[:query].id),
        params: report[:params],
      }
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
