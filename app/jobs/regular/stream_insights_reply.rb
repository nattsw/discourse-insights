# frozen_string_literal: true

module Jobs
  class StreamInsightsReply < ::Jobs::Base
    THROTTLE_INTERVAL = 0.3

    def execute(args)
      user = User.find_by(id: args[:user_id])
      return if user.blank?

      type = args[:type]
      question = args[:question]
      period_opts = args[:period_opts]&.symbolize_keys || { period: "30d" }

      # serve cached response if available (custom questions are never cached)
      if type != "custom"
        cached = Discourse.cache.read(ai_cache_key(type, period_opts))
        if cached.present?
          publish_update(user, type, cached, done: true)
          return
        end
      end

      persona_record = AiPersona.find_by(name: DiscourseInsights::AI_PERSONA_NAME)
      return if persona_record.blank?

      llm_id = persona_record.default_llm_id.presence || SiteSetting.ai_default_llm_model
      llm_model = LlmModel.find_by(id: llm_id)
      return if llm_model.blank?

      metrics_data = fetch_metrics(period_opts)
      prompt_text = build_prompt(type, question, metrics_data)

      persona_class = persona_record.class_instance
      bot =
        DiscourseAi::Personas::Bot.as(
          Discourse.system_user,
          persona: persona_class.new,
          model: llm_model,
        )

      context =
        DiscourseAi::Personas::BotContext.new(
          user: user,
          messages: [{ type: :user, content: prompt_text }],
          skip_show_thinking: true,
          feature_name: "insights",
        )

      streamed_reply = +""
      last_publish = Time.now

      bot.reply(context) do |partial, _placeholder, partial_type|
        next if partial_type

        streamed_reply << partial

        if (Time.now - last_publish) > THROTTLE_INTERVAL || Rails.env.test?
          publish_update(user, type, streamed_reply, done: false)
          last_publish = Time.now
        end
      end

      # cache the completed response (same TTL as health data)
      if type != "custom" && streamed_reply.present?
        Discourse.cache.write(
          ai_cache_key(type, period_opts),
          streamed_reply,
          expires_in: 35.minutes,
        )
      end

      publish_update(user, type, streamed_reply, done: true)
    end

    private

    def ai_cache_key(type, period_opts)
      period_part =
        if period_opts[:start_date].present?
          "custom_#{period_opts[:start_date]}_#{period_opts[:end_date]}"
        else
          period_opts[:period]
        end
      "insights_ai_#{type}_#{period_part}"
    end

    def fetch_metrics(period_opts)
      cache_key =
        if period_opts[:start_date].present?
          "insights_custom_#{period_opts[:start_date]}_#{period_opts[:end_date]}"
        else
          "insights_#{period_opts[:period]}"
        end

      Discourse
        .cache
        .fetch(cache_key, expires_in: 35.minutes) do
          DiscourseInsights::DashboardData.new(**period_opts).compute
        end
    end

    def build_prompt(type, question, data)
      # compact version: drop daily sparkline arrays to save tokens
      compact =
        data
          .except(:ai_available)
          .transform_values do |v|
            next v unless v.is_a?(Hash)
            v.transform_values do |metric|
              next metric unless metric.is_a?(Hash) && metric.key?(:daily)
              metric.except(:daily)
            end
          end

      context_json = compact.to_json

      user_message =
        case type
        when "summary"
          "Generate a **summary** insight for this community data."
        when "categories"
          "Which **categories** need attention? Suggest specific actions."
        when "content"
          "What **content** should be created next based on search gaps and underserved areas?"
        when "deflection"
          "How is **support deflection** trending? How well is the community helping itself?"
        when "stakeholder"
          "Write a **stakeholder** summary suitable for a VP or director."
        when "custom"
          question
        end

      <<~PROMPT
        Here is the community metrics data:

        ```json
        #{context_json}
        ```

        #{user_message}
      PROMPT
    end

    def publish_update(user, type, text, done:)
      MessageBus.publish(
        "/insights/ai/stream",
        { type: type, text: text, done: done },
        user_ids: [user.id],
      )
    end
  end
end
