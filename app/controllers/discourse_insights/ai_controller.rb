# frozen_string_literal: true

module ::DiscourseInsights
  class AiController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    before_action :ensure_logged_in
    before_action :ensure_allowed
    before_action :ensure_ai_available

    ALLOWED_TYPES = %w[summary categories content deflection stakeholder custom].freeze

    def generate
      type = params[:type]
      raise Discourse::InvalidParameters.new(:type) unless ALLOWED_TYPES.include?(type)

      if type == "custom"
        question = params[:question]&.strip
        raise Discourse::InvalidParameters.new(:question) if question.blank?
      end

      period_opts = period_params

      # return cached response inline if available
      if type != "custom"
        cached = Discourse.cache.read(ai_cache_key(type, period_opts))
        if cached.present?
          return render json: { success: true, text: cached }
        end
      end

      RateLimiter.new(current_user, "insights-ai-generate", 10, 1.minute).performed!

      Jobs.enqueue(
        :stream_insights_reply,
        user_id: current_user.id,
        type: type,
        question: question,
        period_opts: period_opts,
      )

      render json: { success: true }
    end

    private

    def ai_cache_key(type, opts)
      period_part =
        if opts[:start_date].present?
          "custom_#{opts[:start_date]}_#{opts[:end_date]}"
        else
          opts[:period]
        end
      "insights_ai_#{type}_#{period_part}"
    end

    def period_params
      if params[:start_date].present? && params[:end_date].present?
        { start_date: params[:start_date], end_date: params[:end_date] }
      else
        period = params[:period]
        period = "30d" unless DashboardData::PERIODS.key?(period)
        { period: period }
      end
    end

    def ensure_allowed
      unless current_user.in_any_groups?(SiteSetting.insights_allowed_groups_map)
        raise Discourse::InvalidAccess
      end
    end

    def ensure_ai_available
      raise Discourse::NotFound unless defined?(DiscourseAi)
      raise Discourse::NotFound unless SiteSetting.discourse_ai_enabled

      persona = AiPersona.find_by(name: DiscourseInsights::AI_PERSONA_NAME)
      raise Discourse::NotFound unless persona

      llm_id = persona.default_llm_id.presence || SiteSetting.ai_default_llm_model
      raise Discourse::NotFound unless LlmModel.exists?(id: llm_id)
    end
  end
end
