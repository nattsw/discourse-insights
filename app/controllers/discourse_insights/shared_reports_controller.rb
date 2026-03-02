# frozen_string_literal: true

module ::DiscourseInsights
  class SharedReportsController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    include DiscourseInsights::AccessControl

    before_action :ensure_logged_in
    before_action :ensure_allowed
    before_action :ensure_data_explorer

    def create
      RateLimiter.new(
        current_user,
        "insights-create-shared-report",
        10,
        1.day,
        apply_limit_to_staff: true,
      ).performed!

      entries = params[:reports]
      raise Discourse::InvalidParameters.new(:reports) if !entries.is_a?(Array) || entries.blank?

      if InsightsSharedReport.where(user_id: current_user.id).count >=
           InsightsSharedReport::MAX_REPORTS_PER_USER
        raise Discourse::InvalidAccess.new(
                nil,
                nil,
                custom_message: "discourse_insights.shared_report.max_reached",
              )
      end

      report_data = validate_and_build_report_data(entries)

      shared_report =
        InsightsSharedReport.create!(
          user_id: current_user.id,
          title: params[:title].presence,
          report_data: report_data,
        )

      render json: { key: shared_report.key }
    end

    def show
      shared_report = InsightsSharedReport.find_by(key: params[:key])
      raise Discourse::NotFound unless shared_report

      filtered = shared_report.reports_for_viewer(guardian)

      render json: {
               key: shared_report.key,
               title: shared_report.title,
               owner: {
                 id: shared_report.user_id,
                 username: shared_report.user&.username,
               },
               is_owner: shared_report.user_id == current_user.id,
               reports:
                 filtered.map do |r|
                   {
                     id: r[:query].id,
                     name: r[:query].name,
                     description: r[:query].description,
                     params: r[:params],
                   }
                 end,
             }
    end

    def update
      shared_report = InsightsSharedReport.find_by(key: params[:key])
      raise Discourse::NotFound unless shared_report
      raise Discourse::InvalidAccess unless shared_report.user_id == current_user.id

      attrs = {}
      attrs[:title] = params[:title] if params.key?(:title)

      if params.key?(:reports)
        entries = params[:reports]
        raise Discourse::InvalidParameters.new(:reports) if !entries.is_a?(Array) || entries.blank?
        attrs[:report_data] = validate_and_build_report_data(entries)
      end

      shared_report.update!(attrs)
      render json: { success: true }
    end

    def destroy
      shared_report = InsightsSharedReport.find_by(key: params[:key])
      raise Discourse::NotFound unless shared_report
      raise Discourse::InvalidAccess unless shared_report.user_id == current_user.id

      shared_report.destroy!
      render json: { success: true }
    end

    private

    MAX_REPORT_ENTRIES = 50

    def validate_and_build_report_data(entries)
      raise Discourse::InvalidParameters.new(:reports) if entries.length > MAX_REPORT_ENTRIES

      parsed =
        entries.map do |entry|
          e = entry.permit(:query_id, params: {}).to_h.deep_symbolize_keys
          qid = e[:query_id].to_i
          raise Discourse::InvalidParameters.new(:query_id) if qid <= 0
          { qid: qid, raw_params: e[:params] || {} }
        end

      query_ids = parsed.map { |p| p[:qid] }
      queries =
        DiscourseDataExplorer::Query.includes(:groups).where(id: query_ids).index_by(&:id)

      parsed.map do |p|
        query = queries[p[:qid]]
        if !query || query.hidden || !guardian.user_can_access_query?(query)
          raise Discourse::NotFound
        end

        non_date_params = p[:raw_params].to_h.reject { |k, _| k.to_s.match?(/date/) }
        { "query_id" => p[:qid], "params" => non_date_params.stringify_keys }
      end
    end

    def ensure_data_explorer
      unless defined?(DiscourseDataExplorer) && SiteSetting.data_explorer_enabled
        raise Discourse::NotFound
      end
    end
  end
end
