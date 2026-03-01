# frozen_string_literal: true

class ResetInsightsUserReports < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      DELETE FROM plugin_store_rows
      WHERE plugin_name = 'discourse-insights'
        AND key LIKE 'reports_%'
        AND key != 'reports_available'
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
