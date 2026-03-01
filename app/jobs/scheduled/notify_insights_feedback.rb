# frozen_string_literal: true

module Jobs
  class NotifyInsightsFeedback < ::Jobs::Scheduled
    every 30.minutes
    sidekiq_options queue: "low"

    def execute(args)
      return unless SiteSetting.insights_enabled

      group_ids = SiteSetting.insights_feedback_notify_group_map
      return if group_ids.blank?

      pending = InsightsFeedback.where(notified: false).includes(:user).order(:created_at)
      return if pending.empty?

      group_names = Group.where(id: group_ids).pluck(:name)
      return if group_names.blank?

      body =
        pending.map do |fb|
          I18n.t(
            "discourse_insights.feedback_pm.item",
            username: fb.user.username,
            comment: fb.comment,
          )
        end.join("\n\n---\n\n")

      title = I18n.t("discourse_insights.feedback_pm.title")

      post =
        PostCreator.create(
          Discourse.system_user,
          target_group_names: group_names,
          archetype: Archetype.private_message,
          subtype: TopicSubtype.system_message,
          title: title,
          raw: body,
          skip_validations: true,
        )

      pending.update_all(notified: true) if post.persisted?
    end
  end
end
