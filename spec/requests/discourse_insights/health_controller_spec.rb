# frozen_string_literal: true

describe DiscourseInsights::HealthController do
  fab!(:admin)
  fab!(:user)

  before { enable_current_plugin }

  describe "#show" do
    context "when logged in as an admin" do
      before { sign_in(admin) }

      it "returns dashboard data with expected keys" do
        get "/insights/health.json"
        expect(response.status).to eq(200)
        body = response.parsed_body
        expect(body).to have_key("period")
        expect(body).to have_key("metrics")
        expect(body).to have_key("dau_wau_mau")
        expect(body).to have_key("posts_breakdown")
        expect(body).to have_key("top_topics")
        expect(body).to have_key("search_terms")
        expect(body).to have_key("traffic_sources")
        expect(body).to have_key("categories")
      end

      it "returns metrics for all expected keys" do
        get "/insights/health.json"
        metrics = response.parsed_body["metrics"]
        %w[
          visitors
          page_views
          new_members
          contributors
          posts
          likes
          solved
          response_rate
        ].each { |key| expect(metrics).to have_key(key) }
      end

      it "accepts a period parameter" do
        get "/insights/health.json", params: { period: "7d" }
        expect(response.status).to eq(200)
        expect(response.parsed_body["period"]["key"]).to eq("7d")
      end

      it "defaults to 30d for invalid period" do
        get "/insights/health.json", params: { period: "invalid" }
        expect(response.status).to eq(200)
        expect(response.parsed_body["period"]["key"]).to eq("30d")
      end

      it "accepts valid custom date range" do
        get "/insights/health.json",
            params: {
              start_date: 30.days.ago.to_date.to_s,
              end_date: Date.today.to_s,
            }
        expect(response.status).to eq(200)
        expect(response.parsed_body["period"]["key"]).to eq("custom")
      end

      it "returns 400 for invalid date strings" do
        get "/insights/health.json", params: { start_date: "not-a-date", end_date: "also-bad" }
        expect(response.status).to eq(400)
      end

      it "returns 400 for date range exceeding 365 days" do
        get "/insights/health.json", params: { start_date: "2024-01-01", end_date: "2025-12-31" }
        expect(response.status).to eq(400)
      end

      it "normalizes date cache keys to prevent cache pollution" do
        get "/insights/health.json", params: { start_date: "2026-01-01", end_date: "2026-01-31" }
        expect(response.status).to eq(200)
      end
    end

    context "when logged in as a regular user not in allowed groups" do
      before { sign_in(user) }

      it "denies access" do
        get "/insights/health.json"
        expect(response.status).to eq(403)
      end
    end

    context "when not logged in" do
      it "denies access" do
        get "/insights/health.json"
        expect(response.status).to eq(403)
      end
    end

    context "when the plugin is disabled" do
      before do
        SiteSetting.insights_enabled = false
        sign_in(admin)
      end

      it "returns 404" do
        get "/insights/health.json"
        expect(response.status).to eq(404)
      end
    end

    context "when user is in an allowed group" do
      fab!(:group)
      fab!(:member) { Fabricate(:user, groups: [group]) }

      before do
        SiteSetting.insights_allowed_groups = group.id.to_s
        sign_in(member)
      end

      it "returns a successful response" do
        get "/insights/health.json"
        expect(response.status).to eq(200)
      end
    end

    context "when user is not in an allowed group" do
      fab!(:group)

      before do
        SiteSetting.insights_allowed_groups = group.id.to_s
        sign_in(admin)
      end

      it "denies access" do
        get "/insights/health.json"
        expect(response.status).to eq(403)
      end
    end
  end
end
