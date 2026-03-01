# frozen_string_literal: true

describe "Insights reports", type: :system do
  fab!(:admin)
  fab!(:category)

  before do
    enable_current_plugin
    SiteSetting.data_explorer_enabled = true
  end

  def create_de_query(name:, sql:)
    DiscourseDataExplorer::Query.create!(
      name: name,
      description: "test query",
      sql: sql,
      user_id: Discourse::SYSTEM_USER_ID,
    )
  end

  def set_user_reports(user, entries)
    user.custom_fields["insights_report_ids"] = entries
    user.save_custom_fields
  end

  def category_header_with_value(id)
    ".insights-report-chart__param-category .select-kit-header[data-value='#{id}']"
  end

  describe "stored params" do
    it "loads stored category_id param on both editor and dashboard" do
      query =
        create_de_query(
          name: "By Category",
          sql:
            "-- [params]\n-- category_id :category_id = Uncategorized\nSELECT 'row1' AS label, 10 AS value UNION ALL SELECT 'row2', 20",
        )
      set_user_reports(
        admin,
        [{ "query_id" => query.id, "params" => { "category_id" => category.id.to_s } }],
      )

      sign_in(admin)

      # verify on editor page
      visit "/insights/reports"
      expect(page).to have_css(".insights-report-editor")
      expect(page).to have_css(".insights-report-chart__canvas-wrap canvas")

      find(".insights-report-chart__toggle-btn").click
      expect(page).to have_css(category_header_with_value(category.id))

      # verify on dashboard
      visit "/insights"
      find(".insights-explore__toggle", text: "My Reports").click
      expect(page).to have_css(".insights-report-chart__canvas-wrap canvas")

      find(".insights-report-chart__toggle-btn").click
      expect(page).to have_css(category_header_with_value(category.id))
    end

    it "saves edited param from editor and loads it on dashboard" do
      query =
        create_de_query(
          name: "With Limit",
          sql:
            "-- [params]\n-- int :limit = 10\nSELECT 'row1' AS label, :limit AS value UNION ALL SELECT 'row2', :limit * 2",
        )
      set_user_reports(admin, [{ "query_id" => query.id, "params" => {} }])

      sign_in(admin)

      visit "/insights/reports"
      expect(page).to have_css(".insights-report-chart__canvas-wrap canvas")

      # expand to see params and change the value
      find(".insights-report-chart__toggle-btn").click
      expect(page).to have_css(".insights-report-chart__params")
      fill_in_param = find(".insights-report-chart__param-input[type='number']")
      fill_in_param.fill_in(with: "42")

      # click title area to blur the input and trigger change event
      find(".insights-report-editor__title").click
      expect(page).to have_css(".insights-report-editor__unsaved")

      # save and confirm dirty state clears
      find(".insights-report-editor__actions .btn-primary").click
      expect(page).to have_no_css(".insights-report-editor__unsaved")

      # navigate to dashboard and verify
      visit "/insights"
      find(".insights-explore__toggle", text: "My Reports").click
      expect(page).to have_css(".insights-report-chart__canvas-wrap canvas")

      find(".insights-report-chart__toggle-btn").click
      expect(page).to have_css(".insights-report-chart__params")
      expect(find(".insights-report-chart__param-input[type='number']").value).to eq("42")
    end
  end

  describe "editor navigation" do
    it "navigates from dashboard to editor and back" do
      query = create_de_query(name: "Simple Count", sql: "SELECT 1 AS value")
      set_user_reports(admin, [{ "query_id" => query.id, "params" => {} }])

      sign_in(admin)
      visit "/insights"

      find(".insights-explore__toggle", text: "My Reports").click
      expect(page).to have_css(".insights-report-chart")

      find(".insights-reports-editor-link").click
      expect(page).to have_css(".insights-report-editor")
      expect(page).to have_current_path(/\/insights\/reports/)

      find(".insights-report-editor__title-row .btn-transparent").click
      expect(page).to have_css(".insights-metrics")
      expect(page).to have_current_path(/\/insights$/)
    end
  end
end
