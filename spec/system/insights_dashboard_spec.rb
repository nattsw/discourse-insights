# frozen_string_literal: true

describe "Insights page", type: :system do
  fab!(:admin)
  fab!(:user)

  before { enable_current_plugin }

  context "when an admin visits the page" do
    it "renders the dashboard with insights section" do
      sign_in(admin)
      visit "/insights"

      expect(page).to have_css(".insights")
      expect(page).to have_css("h2", text: "Insights")
      expect(page).to have_css(".insights-summary")
      expect(page).to have_css(".insights-metrics")
    end
  end

  context "when a user in an allowed group visits the page" do
    fab!(:group)

    before { SiteSetting.insights_allowed_groups = "1|#{group.id}" }

    it "renders the page" do
      group.add(user)
      sign_in(user)
      visit "/insights"

      expect(page).to have_css(".insights")
    end
  end

  context "when plugin is disabled" do
    before { SiteSetting.insights_enabled = false }

    it "does not render the insights page" do
      sign_in(admin)
      visit "/insights"

      expect(page).to have_no_css(".insights")
    end
  end
end
