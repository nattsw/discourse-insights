# frozen_string_literal: true

module ::DiscourseInsights
  class InsightsReportRunner
    def initialize(query, user, params = {})
      @query = query
      @user = user
      @params = params
    end

    def run
      query_params = {}
      @query.params.each do |p|
        query_params[p.identifier] = @params[p.identifier] if @params[p.identifier].present?
      end

      cache_key = "insights_report_#{@query.id}_#{query_params.sort.to_h.values.join("_")}"
      cached = Discourse.cache.read(cache_key)
      return cached if cached

      result =
        DiscourseDataExplorer::DataExplorer.run_query(
          @query,
          query_params,
          { current_user: @user, limit: 1000 },
        )

      raise result[:error] if result[:error]

      pg = result[:pg_result]
      response = {
        columns: pg.fields,
        rows: pg.values,
        params:
          @query.params.map do |p|
            {
              identifier: p.identifier,
              type: p.type,
              default: p.default,
              value: query_params[p.identifier],
            }
          end,
      }
      Discourse.cache.write(cache_key, response, expires_in: 35.minutes)
      response
    end
  end
end
