# frozen_string_literal: true

class InsightsFeedback < ActiveRecord::Base
  self.table_name = "insights_feedback"

  belongs_to :user
  validates :comment, presence: true, length: { maximum: 10_000 }
end
