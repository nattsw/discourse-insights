# frozen_string_literal: true

describe DiscourseInsights::ReportsController do
  fab!(:admin)
  fab!(:user)

  before { enable_current_plugin }

  def create_de_query(name: "Test Query", sql: "SELECT 1 AS value")
    DiscourseDataExplorer::Query.create!(
      name: name,
      description: "A test query",
      sql: sql,
      user_id: Discourse::SYSTEM_USER_ID,
    )
  end

  describe "#index" do
    context "when logged in as admin" do
      before { sign_in(admin) }

      it "returns seeded reports for a new user" do
        query = create_de_query
        PluginStore.set("discourse-insights", "seeded_query_ids", [query.id])

        get "/insights/reports.json"
        expect(response.status).to eq(200)

        reports = response.parsed_body["reports"]
        expect(reports.length).to eq(1)
        expect(reports[0]["id"]).to eq(query.id)
        expect(reports[0]["name"]).to eq("Test Query")
        expect(reports[0]["insights"]).to eq(true)
      end

      it "returns user-specific reports when customized" do
        q1 = create_de_query(name: "Query 1")
        q2 = create_de_query(name: "Query 2")
        PluginStore.set("discourse-insights", "seeded_query_ids", [q1.id])
        PluginStore.set("discourse-insights", "reports_#{admin.id}", [q1.id, q2.id])

        get "/insights/reports.json"
        reports = response.parsed_body["reports"]
        expect(reports.length).to eq(2)

        seeded = reports.find { |r| r["id"] == q1.id }
        custom = reports.find { |r| r["id"] == q2.id }
        expect(seeded["insights"]).to eq(true)
        expect(custom["insights"]).to eq(false)
      end

      it "skips deleted queries" do
        PluginStore.set("discourse-insights", "reports_#{admin.id}", [99_999])

        get "/insights/reports.json"
        expect(response.parsed_body["reports"]).to be_empty
      end
    end

    context "when not logged in" do
      it "denies access" do
        get "/insights/reports.json"
        expect(response.status).to eq(403)
      end
    end

    context "when user is not in allowed groups" do
      before { sign_in(user) }

      it "denies access" do
        get "/insights/reports.json"
        expect(response.status).to eq(403)
      end
    end
  end

  describe "#run" do
    before { sign_in(admin) }

    it "executes a query and returns columns and rows" do
      query = create_de_query(sql: "SELECT 1 AS num, 'hello' AS word")

      get "/insights/reports/#{query.id}/run.json"
      expect(response.status).to eq(200)

      body = response.parsed_body
      expect(body["columns"]).to eq(%w[num word])
      expect(body["rows"].first).to eq([1, "hello"])
    end

    it "returns 404 for non-existent query" do
      get "/insights/reports/99999/run.json"
      expect(response.status).to eq(404)
    end

    it "forwards date params to parameterized queries" do
      query =
        create_de_query(
          sql:
            "-- [params]\n-- date :start_date = 2025-01-01\n-- date :end_date = 2025-12-31\nSELECT :start_date::date AS from_date, :end_date::date AS to_date",
        )

      get "/insights/reports/#{query.id}/run.json",
          params: {
            start_date: "2026-01-01",
            end_date: "2026-02-01",
          }
      expect(response.status).to eq(200)

      body = response.parsed_body
      expect(body["rows"].first).to eq(%w[2026-01-01 2026-02-01])
    end

    it "uses query defaults when no date params provided" do
      query =
        create_de_query(
          sql:
            "-- [params]\n-- date :start_date = 2025-06-15\nSELECT :start_date::date AS from_date",
        )

      get "/insights/reports/#{query.id}/run.json"
      expect(response.status).to eq(200)

      body = response.parsed_body
      expect(body["rows"].first).to eq(%w[2025-06-15])
    end
  end

  describe "#add" do
    before { sign_in(admin) }

    it "adds a query to the user's reports" do
      query = create_de_query

      post "/insights/reports.json", params: { query_id: query.id }
      expect(response.status).to eq(200)

      ids = PluginStore.get("discourse-insights", "reports_#{admin.id}")
      expect(ids).to include(query.id)
    end

    it "does not duplicate an already-added query" do
      query = create_de_query
      PluginStore.set("discourse-insights", "reports_#{admin.id}", [query.id])

      post "/insights/reports.json", params: { query_id: query.id }
      expect(response.status).to eq(200)

      ids = PluginStore.get("discourse-insights", "reports_#{admin.id}")
      expect(ids.count(query.id)).to eq(1)
    end

    it "returns 404 for non-existent query" do
      post "/insights/reports.json", params: { query_id: 99_999 }
      expect(response.status).to eq(404)
    end
  end

  describe "#remove" do
    before { sign_in(admin) }

    it "removes a query from the user's reports" do
      query = create_de_query
      PluginStore.set("discourse-insights", "reports_#{admin.id}", [query.id])

      delete "/insights/reports/#{query.id}.json"
      expect(response.status).to eq(200)

      ids = PluginStore.get("discourse-insights", "reports_#{admin.id}")
      expect(ids).not_to include(query.id)
    end
  end

  describe "#available" do
    before { sign_in(admin) }

    it "returns all non-hidden queries with pinned and insights status" do
      q1 = create_de_query(name: "Public Query")
      q2 = create_de_query(name: "Hidden Query")
      q2.update!(hidden: true)
      q3 = create_de_query(name: "Custom Query")

      PluginStore.set("discourse-insights", "seeded_query_ids", [q1.id])
      PluginStore.set("discourse-insights", "reports_#{admin.id}", [q1.id])

      get "/insights/reports/available.json"
      expect(response.status).to eq(200)

      queries = response.parsed_body["queries"]
      expect(queries.map { |q| q["name"] }).to include("Public Query")
      expect(queries.map { |q| q["name"] }).not_to include("Hidden Query")

      pinned = queries.find { |q| q["id"] == q1.id }
      expect(pinned["pinned"]).to eq(true)
      expect(pinned["insights"]).to eq(true)

      custom = queries.find { |q| q["id"] == q3.id }
      expect(custom["insights"]).to eq(false)
    end
  end
end
