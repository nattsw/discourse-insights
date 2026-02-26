# frozen_string_literal: true

module ::DiscourseInsights
  class PageController < ::ApplicationController
    def index
      render html: "", layout: "application"
    end
  end
end
