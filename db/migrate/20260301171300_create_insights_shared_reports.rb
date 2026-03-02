# frozen_string_literal: true

class CreateInsightsSharedReports < ActiveRecord::Migration[7.2]
  def change
    create_table :insights_shared_reports do |t|
      t.string :key, limit: 16, null: false
      t.string :title, limit: 255
      t.integer :user_id, null: false
      t.jsonb :report_data, null: false, default: "[]"
      t.timestamps
    end

    add_index :insights_shared_reports, :key, unique: true
    add_index :insights_shared_reports, :user_id
  end
end
