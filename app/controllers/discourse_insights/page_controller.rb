# frozen_string_literal: true

module ::DiscourseInsights
  class PageController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    def index
      render html: "", layout: "application"
    end
  end
end
