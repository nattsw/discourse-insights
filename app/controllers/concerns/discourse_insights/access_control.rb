# frozen_string_literal: true

module ::DiscourseInsights
  module AccessControl
    extend ActiveSupport::Concern

    private

    def ensure_allowed
      unless current_user.in_any_groups?(SiteSetting.insights_allowed_groups_map)
        raise Discourse::InvalidAccess
      end
    end
  end
end
