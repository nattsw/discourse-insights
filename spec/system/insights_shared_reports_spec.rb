# frozen_string_literal: true

describe "Insights shared reports", type: :system do
  fab!(:admin)
  fab!(:group)
  fab!(:member) { Fabricate(:user, groups: [group]) }

  before do
    enable_current_plugin
    SiteSetting.data_explorer_enabled = true
    SiteSetting.insights_allowed_groups = "#{Group::AUTO_GROUPS[:admins]}|#{group.id}"
  end

  def create_de_query(name:, sql:, groups: [])
    query =
      DiscourseDataExplorer::Query.create!(
        name: name,
        description: "test query",
        sql: sql,
        user_id: Discourse::SYSTEM_USER_ID,
      )
    groups.each do |g|
      DiscourseDataExplorer::QueryGroup.create!(query_id: query.id, group_id: g.id)
    end
    query
  end

  def set_user_reports(user, entries)
    user.custom_fields["insights_report_ids"] = entries
    user.save_custom_fields
  end

  describe "sharing flow" do
    it "creates a shared report from the editor and lands on shared page" do
      query =
        create_de_query(
          name: "Simple Count",
          sql: "SELECT 'row1' AS label, 10 AS value UNION ALL SELECT 'row2', 20",
        )
      set_user_reports(admin, [{ "query_id" => query.id, "params" => {} }])

      sign_in(admin)
      visit "/insights/reports"
      expect(page).to have_css(".insights-report-editor")
      expect(page).to have_css(".insights-report-chart__canvas-wrap canvas")

      find(".insights-report-editor__actions .btn-default", text: "Share").click

      expect(page).to have_css(".insights-shared-report")
      expect(page).to have_current_path(%r{/insights/reports/[a-f0-9]{16}})
      expect(page).to have_css(".insights-shared-report__share-url-input")
      expect(page).to have_css(".insights-report-chart__canvas-wrap canvas")
    end
  end

  describe "owner vs viewer" do
    fab!(:query) do
      DiscourseDataExplorer::Query.create!(
        name: "Shared Query",
        description: "test",
        sql: "SELECT 'row1' AS label, 10 AS value",
        user_id: Discourse::SYSTEM_USER_ID,
      )
    end

    fab!(:shared_report) do
      InsightsSharedReport.create!(
        user_id: admin.id,
        title: "My Dashboard",
        report_data: [{ "query_id" => query.id, "params" => {} }],
      )
    end

    before { DiscourseDataExplorer::QueryGroup.create!(query_id: query.id, group_id: group.id) }

    it "owner sees edit controls" do
      sign_in(admin)
      visit "/insights/reports/#{shared_report.key}"

      expect(page).to have_css(".insights-shared-report__title-input")
      expect(page).to have_css(".btn-primary", text: "Save")
      expect(page).to have_css(".btn-danger", text: "Delete")
      expect(page).to have_css(".insights-report-chart")
    end

    it "viewer sees read-only view" do
      sign_in(member)
      visit "/insights/reports/#{shared_report.key}"

      expect(page).to have_css(".insights-shared-report__title", text: "My Dashboard")
      expect(page).to have_no_css(".insights-shared-report__title-input")
      expect(page).to have_no_css(".btn-primary", text: "Save")
      expect(page).to have_no_css(".btn-danger", text: "Delete")
      expect(page).to have_css(".insights-report-chart")
      expect(page).to have_no_css(".insights-report-chart__remove")
      expect(page).to have_no_css(".insights-report-chart__grip")
    end
  end

  describe "query access filtering" do
    it "hides charts for queries the viewer cannot access" do
      accessible =
        create_de_query(
          name: "Accessible",
          sql: "SELECT 'a' AS label, 1 AS value",
          groups: [group],
        )
      restricted_group = Fabricate(:group)
      restricted =
        create_de_query(
          name: "Restricted",
          sql: "SELECT 'r' AS label, 2 AS value",
          groups: [restricted_group],
        )

      shared =
        InsightsSharedReport.create!(
          user_id: admin.id,
          report_data: [
            { "query_id" => accessible.id, "params" => {} },
            { "query_id" => restricted.id, "params" => {} },
          ],
        )

      sign_in(member)
      visit "/insights/reports/#{shared.key}"

      expect(page).to have_css(".insights-report-chart", count: 1)
      expect(page).to have_css(".insights-report-chart__title", text: "Accessible")
      expect(page).to have_no_css(".insights-report-chart__title", text: "Restricted")
    end
  end
end
