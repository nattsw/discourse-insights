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
            query = DiscourseDataExplorer::Query.find(id)
            query if !query.hidden && guardian.user_can_access_query?(query)
          rescue ActiveRecord::RecordNotFound
            nil
          end
        end

      render json: {
               reports:
                 queries.map do |q|
                   {
                     id: q.id,
                     name: q.name,
                     description: q.description,
                     insights: seeded_query_id_set.include?(q.id),
                   }
                 end,
             }
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

      query_params = {}
      query.params.each do |p|
        query_params[p.identifier] = params[p.identifier] if params[p.identifier].present?
      end

      cache_key = "insights_report_#{query_id}_#{query_params.sort.to_h.values.join("_")}"
      cached = Discourse.cache.read(cache_key)
      if cached
        render json: cached
        return
      end

      result =
        DiscourseDataExplorer::DataExplorer.run_query(
          query,
          query_params,
          { current_user: current_user, limit: 1000 },
        )

      if result[:error]
        render json: { error: result[:error].message }, status: :unprocessable_entity
        return
      end

      pg = result[:pg_result]
      response = {
        columns: pg.fields,
        rows: pg.values,
        params:
          query.params.map do |p|
            {
              identifier: p.identifier,
              type: p.type,
              default: p.default,
              value: query_params[p.identifier],
            }
          end,
      }
      Discourse.cache.write(cache_key, response, expires_in: 35.minutes)
      render json: response
    end

    def add
      query_id = params[:query_id].to_i
      query = DiscourseDataExplorer::Query.find(query_id)
      raise Discourse::NotFound if query.hidden || !guardian.user_can_access_query?(query)

      ids = user_report_ids
      if ids.exclude?(query_id)
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
      all_queries = DiscourseDataExplorer::Query.includes(:groups).where(hidden: false).order(:name)
      pinned = user_report_ids

      render json: {
               queries:
                 all_queries
                   .select { |q| guardian.user_can_access_query?(q) }
                   .map do |q|
                     {
                       id: q.id,
                       name: q.name,
                       description: q.description,
                       pinned: pinned.include?(q.id),
                       insights: seeded_query_id_set.include?(q.id),
                     }
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

    def seeded_query_id_set
      @seeded_query_id_set ||= Set.new(PluginStore.get(PLUGIN_NAME, "seeded_query_ids") || [])
    end

    def ensure_allowed
      unless current_user.in_any_groups?(SiteSetting.insights_allowed_groups_map)
        raise Discourse::InvalidAccess
      end
    end

    def ensure_data_explorer
      unless defined?(DiscourseDataExplorer) && SiteSetting.data_explorer_enabled
        raise Discourse::NotFound
      end
    end
  end
end
