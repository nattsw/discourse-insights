# frozen_string_literal: true

module ::DiscourseInsights
  class InsightsReportList
    def initialize(user, guardian)
      @user = user
      @guardian = guardian
    end

    def user_reports
      query_ids = user_report_ids
      query_ids.filter_map do |id|
        query = DiscourseDataExplorer::Query.find_by(id: id)
        next unless query && !query.hidden && @guardian.user_can_access_query?(query)
        query
      end
    end

    def available_reports
      DiscourseDataExplorer::Query
        .includes(:groups)
        .where(hidden: false)
        .order(:name)
        .select { |q| @guardian.user_can_access_query?(q) }
    end

    def add_report(query_id)
      ids = user_report_ids
      ids << query_id if ids.exclude?(query_id)
      save_user_report_ids(ids)
    end

    def remove_report(query_id)
      ids = user_report_ids
      ids.delete(query_id)
      save_user_report_ids(ids)
    end

    def user_report_ids
      PluginStore.get(PLUGIN_NAME, "reports_#{@user.id}") || default_report_ids
    end

    def seeded_query_ids
      @seeded_query_ids ||= Set.new(PluginStore.get(PLUGIN_NAME, "seeded_query_ids") || [])
    end

    private

    def save_user_report_ids(ids)
      PluginStore.set(PLUGIN_NAME, "reports_#{@user.id}", ids)
    end

    def default_report_ids
      (PluginStore.get(PLUGIN_NAME, "seeded_query_ids") || []).first(4)
    end
  end
end
