# frozen_string_literal: true

class RenameInsightsSeededQueries < ActiveRecord::Migration[7.2]
  RENAMES = {
    "Weekly Active Users" => "Active Users",
    "New Signups Per Week" => "New Signups",
    "Posts Per Week" => "Posts Created",
    "Likes Per Week" => "Likes Given",
    "Solved Topics Per Week" => "Solved Topics",
    "Unanswered Topics Per Week" => "Unanswered Topics",
    "Avg First Response Time Per Week" => "Avg First Response Time",
    "Engaged Users Per Week" => "Engaged Users",
    "Trust Level Promotions Per Week" => "Trust Level Promotions",
    "Member Lifecycle Per Week" => "Member Lifecycle",
  }.freeze

  def up
    seeded_ids =
      DB.query_single(
        "SELECT value FROM plugin_store_rows WHERE plugin_name = 'discourse-insights' AND key = 'seeded_query_ids'",
      ).first

    return if seeded_ids.blank?

    ids = JSON.parse(seeded_ids)
    return if ids.empty?

    RENAMES.each do |old_name, new_name|
      DB.exec(<<~SQL, old_name: old_name, new_name: new_name, ids: ids)
        UPDATE data_explorer_queries
        SET name = :new_name
        WHERE name = :old_name
          AND id IN (:ids)
      SQL
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
