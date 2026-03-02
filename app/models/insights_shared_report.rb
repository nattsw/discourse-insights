# frozen_string_literal: true

class InsightsSharedReport < ActiveRecord::Base
  MAX_REPORTS_PER_USER = 50

  belongs_to :user

  validates :key, presence: true, uniqueness: true, length: { maximum: 16 }
  validates :user_id, presence: true
  validates :report_data, presence: true
  validates :title, length: { maximum: 255 }

  before_validation :generate_key, on: :create

  def reports_for_viewer(guardian)
    entries = report_data || []
    query_ids = entries.map { |e| e["query_id"] }
    queries =
      DiscourseDataExplorer::Query
        .includes(:groups)
        .where(id: query_ids, hidden: false)
        .index_by(&:id)

    entries.filter_map do |entry|
      query = queries[entry["query_id"]]
      next unless query && guardian.user_can_access_query?(query)
      { query: query, params: entry["params"] || {} }
    end
  end

  private

  def generate_key
    self.key ||= SecureRandom.hex(8)
  end
end
