# frozen_string_literal: true

class CreateInsightsUserGeos < ActiveRecord::Migration[7.2]
  def change
    create_table :insights_user_geos do |t|
      t.integer :user_id, null: false
      t.string :country_code, limit: 2
      t.string :country, limit: 100
      t.string :region, limit: 100
      t.string :city, limit: 100
      t.float :latitude
      t.float :longitude
      t.inet :ip_address
      t.timestamps
    end

    add_index :insights_user_geos, :user_id, unique: true
    add_index :insights_user_geos, :country_code
  end
end
