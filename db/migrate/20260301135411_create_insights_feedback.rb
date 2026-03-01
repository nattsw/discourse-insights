# frozen_string_literal: true

class CreateInsightsFeedback < ActiveRecord::Migration[7.2]
  def change
    create_table :insights_feedback do |t|
      t.integer :user_id, null: false
      t.text :comment, null: false
      t.boolean :notified, default: false, null: false
      t.timestamps
    end

    add_index :insights_feedback, :user_id
    add_index :insights_feedback, :created_at
  end
end
