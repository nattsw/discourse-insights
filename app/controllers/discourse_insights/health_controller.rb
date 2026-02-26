# frozen_string_literal: true

module ::DiscourseInsights
  class HealthController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    before_action :ensure_logged_in
    before_action :ensure_allowed

    def show
      if params[:start_date].present? && params[:end_date].present?
        start_date = params[:start_date]
        end_date = params[:end_date]
        cache_key = "insights_custom_#{start_date}_#{end_date}"
        data_opts = { start_date:, end_date: }
      else
        period = params[:period]
        period = "30d" unless DashboardData::PERIODS.key?(period)
        cache_key = "insights_#{period}"
        data_opts = { period: }
      end

      if params[:force].present?
        RateLimiter.new(current_user, "insights-refresh", 5, 1.minute).performed!
        Discourse.cache.delete(cache_key)
      end

      data =
        Discourse
          .cache
          .fetch(cache_key, expires_in: 35.minutes) { DashboardData.new(**data_opts).compute }

      data[:ai_available] = ai_available?

      render json: data
    end

    private

    def ensure_allowed
      unless current_user.in_any_groups?(SiteSetting.insights_allowed_groups_map)
        raise Discourse::InvalidAccess
      end
    end

    def ai_available?
      return false unless defined?(DiscourseAi)
      return false unless SiteSetting.discourse_ai_enabled
      persona = AiPersona.find_by(name: DiscourseInsights::AI_PERSONA_NAME)
      return false unless persona
      llm_id = persona.default_llm_id.presence || SiteSetting.ai_default_llm_model
      LlmModel.exists?(id: llm_id)
    end
  end
end
