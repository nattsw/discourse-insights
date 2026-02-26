# frozen_string_literal: true

module ::DiscourseInsights
  class ReportsController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    before_action :ensure_logged_in
    before_action :ensure_allowed
    before_action :ensure_data_explorer

    def index
      query_ids = user_report_ids
      queries =
        query_ids.filter_map do |id|
          begin
            DiscourseDataExplorer::Query.find(id)
          rescue ActiveRecord::RecordNotFound
            nil
          end
        end

      render json: {
               reports: queries.map { |q| { id: q.id, name: q.name, description: q.description } },
             }
    end

    def run
      query_id = params[:id].to_i
      query = DiscourseDataExplorer::Query.find(query_id)

      query_params = {}
      query.params.each do |p|
        query_params[p.identifier] = params[p.identifier] if params[p.identifier].present?
      end

      result =
        DiscourseDataExplorer::DataExplorer.run_query(
          query,
          query_params,
          { current_user: current_user, limit: 1000 },
        )

      if result[:error]
        render json: { error: result[:error].message }, status: 422
        return
      end

      pg = result[:pg_result]
      render json: { columns: pg.fields, rows: pg.values }
    end

    def add
      query_id = params[:query_id].to_i
      DiscourseDataExplorer::Query.find(query_id)

      ids = user_report_ids
      unless ids.include?(query_id)
        ids << query_id
        save_user_report_ids(ids)
      end

      render json: { success: true }
    end

    def remove
      query_id = params[:id].to_i
      ids = user_report_ids
      ids.delete(query_id)
      save_user_report_ids(ids)

      render json: { success: true }
    end

    def available
      all_queries = DiscourseDataExplorer::Query.where(hidden: false).order(:name)
      pinned = user_report_ids

      render json: {
               queries:
                 all_queries.map do |q|
                   { id: q.id, name: q.name, description: q.description, pinned: pinned.include?(q.id) }
                 end,
             }
    end

    private

    def user_report_ids
      PluginStore.get(PLUGIN_NAME, "reports_#{current_user.id}") || default_report_ids
    end

    def save_user_report_ids(ids)
      PluginStore.set(PLUGIN_NAME, "reports_#{current_user.id}", ids)
    end

    def default_report_ids
      (PluginStore.get(PLUGIN_NAME, "seeded_query_ids") || []).dup
    end

    def ensure_allowed
      unless current_user.in_any_groups?(SiteSetting.insights_allowed_groups_map)
        raise Discourse::InvalidAccess
      end
    end

    def ensure_data_explorer
      raise Discourse::NotFound unless defined?(DiscourseDataExplorer)
    end
  end
end
