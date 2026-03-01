# frozen_string_literal: true

module ::DiscourseInsights
  class FeedbackController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    include DiscourseInsights::AccessControl

    before_action :ensure_logged_in
    before_action :ensure_allowed

    def create
      RateLimiter.new(
        current_user,
        "insights-feedback",
        5,
        1.day,
        apply_limit_to_staff: true,
      ).performed!

      comment = params.require(:comment)
      feedback = InsightsFeedback.new(user: current_user, comment: comment)

      if feedback.save
        render json: { success: true }
      else
        render_json_error(feedback)
      end
    end
  end
end
