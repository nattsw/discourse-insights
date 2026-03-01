# frozen_string_literal: true

module ::DiscourseInsights
  class InsightsReportList
    MAX_REPORTS = 50

    def initialize(user, guardian)
      @user = user
      @guardian = guardian
    end

    def user_reports
      entries = user_report_entries
      ids = entries.map { |e| e[:query_id] }
      queries = DiscourseDataExplorer::Query.includes(:groups).where(id: ids).index_by(&:id)
      entries.filter_map do |entry|
        query = queries[entry[:query_id]]
        next unless query && !query.hidden && @guardian.user_can_access_query?(query)
        { query: query, params: entry[:params] }
      end
    end

    def available_reports
      DiscourseDataExplorer::Query
        .includes(:groups)
        .where(hidden: false)
        .order(:name)
        .select { |q| @guardian.user_can_access_query?(q) }
    end

    def find_accessible_query!(query_id)
      query = DiscourseDataExplorer::Query.find(query_id)
      raise Discourse::NotFound if query.hidden || !@guardian.user_can_access_query?(query)
      query
    end

    def add_report(query_id, params = {})
      entries = user_report_entries
      return if entries.any? { |e| e[:query_id] == query_id }
      return if entries.length >= MAX_REPORTS
      entries << { query_id: query_id, params: params }
      save_user_report_entries(entries)
    end

    def remove_report(query_id)
      entries = user_report_entries
      entries.reject! { |e| e[:query_id] == query_id }
      save_user_report_entries(entries)
    end

    def reorder(new_ids)
      current = Set.new(user_report_ids)
      new_set = Set.new(new_ids)
      return unless current == new_set
      entries = user_report_entries
      entries_by_id = entries.index_by { |e| e[:query_id] }
      reordered = new_ids.map { |id| entries_by_id[id] }.compact
      save_user_report_entries(reordered)
    end

    def save_all(raw_entries)
      raise Discourse::InvalidParameters.new(:reports) if raw_entries.length > MAX_REPORTS

      query_ids = raw_entries.map { |e| e[:query_id].to_i }
      raise Discourse::InvalidParameters.new(:query_id) if query_ids.any? { |id| id <= 0 }

      queries = DiscourseDataExplorer::Query.includes(:groups).where(id: query_ids).index_by(&:id)

      entries =
        raw_entries.map do |entry|
          qid = entry[:query_id].to_i
          query = queries[qid]
          if !query || query.hidden || !@guardian.user_can_access_query?(query)
            raise Discourse::NotFound
          end

          non_date_params = (entry[:params] || {}).to_h.reject { |k, _| k.to_s.match?(/date/) }
          { query_id: qid, params: non_date_params }
        end

      save_user_report_entries(entries)
    end

    def user_report_ids
      user_report_entries.map { |e| e[:query_id] }
    end

    def user_report_entries
      raw = @user.custom_fields[DiscourseInsights::REPORT_IDS_CUSTOM_FIELD]
      normalize_entries(raw.presence || default_report_entries)
    end

    def seeded_query_ids
      @seeded_query_ids ||= Set.new(PluginStore.get(PLUGIN_NAME, "seeded_query_ids") || [])
    end

    private

    def normalize_entries(raw)
      return [] unless raw.is_a?(Array)

      raw
        .map do |item|
          case item
          when Integer
            { query_id: item, params: {} }
          when Hash
            {
              query_id: item["query_id"]&.to_i || item[:query_id]&.to_i,
              params: item["params"] || item[:params] || {},
            }
          else
            item.to_i > 0 ? { query_id: item.to_i, params: {} } : nil
          end
        end
        .compact
    end

    def save_user_report_entries(entries)
      serialized = entries.map { |e| { "query_id" => e[:query_id], "params" => e[:params] || {} } }
      @user.custom_fields[DiscourseInsights::REPORT_IDS_CUSTOM_FIELD] = serialized
      @user.save_custom_fields
    end

    def default_report_entries
      ids = (PluginStore.get(PLUGIN_NAME, "seeded_query_ids") || []).first(4)
      ids.map { |id| { query_id: id, params: {} } }
    end
  end
end
