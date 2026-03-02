# frozen_string_literal: true

describe "DiscourseInsights::SharedReportsController" do
  fab!(:admin)
  fab!(:user)
  fab!(:group)
  fab!(:member) { Fabricate(:user, groups: [group]) }

  before do
    enable_current_plugin
    SiteSetting.data_explorer_enabled = true
  end

  def create_de_query(name: "Test Query", sql: "SELECT 1 AS value", groups: [])
    query =
      DiscourseDataExplorer::Query.create!(
        name: name,
        description: "A test query",
        sql: sql,
        user_id: Discourse::SYSTEM_USER_ID,
      )
    groups.each do |g|
      DiscourseDataExplorer::QueryGroup.create!(query_id: query.id, group_id: g.id)
    end
    query
  end

  describe "#create" do
    context "when logged in as admin" do
      before { sign_in(admin) }

      it "creates a shared report and returns the key" do
        query = create_de_query

        post "/insights/shared-reports.json",
             params: {
               reports: [{ query_id: query.id, params: {} }],
             }
        expect(response.status).to eq(200)

        body = response.parsed_body
        expect(body["key"]).to be_present
        expect(body["key"].length).to eq(16)

        shared = InsightsSharedReport.find_by(key: body["key"])
        expect(shared.user_id).to eq(admin.id)
        expect(shared.report_data.length).to eq(1)
        expect(shared.report_data[0]["query_id"]).to eq(query.id)
      end

      it "saves an optional title" do
        query = create_de_query

        post "/insights/shared-reports.json",
             params: {
               title: "My Dashboard",
               reports: [{ query_id: query.id, params: {} }],
             }
        expect(response.status).to eq(200)

        shared = InsightsSharedReport.find_by(key: response.parsed_body["key"])
        expect(shared.title).to eq("My Dashboard")
      end

      it "strips date params from report_data" do
        query = create_de_query

        post "/insights/shared-reports.json",
             params: {
               reports: [
                 {
                   query_id: query.id,
                   params: {
                     category_id: "3",
                     start_date: "2026-01-01",
                     end_date: "2026-02-01",
                   },
                 },
               ],
             }
        expect(response.status).to eq(200)

        shared = InsightsSharedReport.find_by(key: response.parsed_body["key"])
        expect(shared.report_data[0]["params"]).to eq({ "category_id" => "3" })
      end

      it "rejects missing reports param" do
        post "/insights/shared-reports.json"
        expect(response.status).to eq(400)
      end

      it "rejects queries the user cannot access" do
        other_group = Fabricate(:group)
        query = create_de_query(groups: [other_group])

        sign_in(member)
        SiteSetting.insights_allowed_groups = "#{Group::AUTO_GROUPS[:admins]}|#{group.id}"

        post "/insights/shared-reports.json",
             params: {
               reports: [{ query_id: query.id, params: {} }],
             }
        expect(response.status).to eq(404)
      end

      it "enforces max reports per user" do
        query = create_de_query

        InsightsSharedReport::MAX_REPORTS_PER_USER.times do
          InsightsSharedReport.create!(user_id: admin.id, report_data: [{ "query_id" => query.id }])
        end

        post "/insights/shared-reports.json",
             params: {
               reports: [{ query_id: query.id, params: {} }],
             }
        expect(response.status).to eq(403)
      end

      it "is rate limited" do
        query = create_de_query
        RateLimiter.enable

        10.times do
          post "/insights/shared-reports.json",
               params: {
                 reports: [{ query_id: query.id, params: {} }],
               }
          expect(response.status).to eq(200)
        end

        post "/insights/shared-reports.json",
             params: {
               reports: [{ query_id: query.id, params: {} }],
             }
        expect(response.status).to eq(429)
      end
    end

    context "when not logged in" do
      it "denies access" do
        post "/insights/shared-reports.json", params: { reports: [{ query_id: 1, params: {} }] }
        expect(response.status).to eq(403)
      end
    end

    context "when user is not in allowed groups" do
      before { sign_in(user) }

      it "denies access" do
        post "/insights/shared-reports.json", params: { reports: [{ query_id: 1, params: {} }] }
        expect(response.status).to eq(403)
      end
    end
  end

  describe "#show" do
    it "denies access when not logged in" do
      query = create_de_query
      shared =
        InsightsSharedReport.create!(
          user_id: admin.id,
          report_data: [{ "query_id" => query.id, "params" => {} }],
        )

      get "/insights/shared-reports/#{shared.key}.json"
      expect(response.status).to eq(403)
    end

    it "returns the shared report for allowed-group user" do
      SiteSetting.insights_allowed_groups = "#{Group::AUTO_GROUPS[:admins]}|#{group.id}"
      query = create_de_query(groups: [group])
      shared =
        InsightsSharedReport.create!(
          user_id: admin.id,
          title: "Test Report",
          report_data: [{ "query_id" => query.id, "params" => {} }],
        )

      sign_in(member)
      get "/insights/shared-reports/#{shared.key}.json"
      expect(response.status).to eq(200)

      body = response.parsed_body
      expect(body["key"]).to eq(shared.key)
      expect(body["title"]).to eq("Test Report")
      expect(body["owner"]["username"]).to eq(admin.username)
      expect(body["is_owner"]).to eq(false)
      expect(body["reports"].length).to eq(1)
      expect(body["reports"][0]["id"]).to eq(query.id)
    end

    it "includes is_owner flag for the owner" do
      query = create_de_query
      shared =
        InsightsSharedReport.create!(
          user_id: admin.id,
          report_data: [{ "query_id" => query.id, "params" => {} }],
        )

      sign_in(admin)
      get "/insights/shared-reports/#{shared.key}.json"
      expect(response.parsed_body["is_owner"]).to eq(true)
    end

    it "returns 404 for bad key" do
      sign_in(admin)
      get "/insights/shared-reports/nonexistentkey.json"
      expect(response.status).to eq(404)
    end

    it "returns 403 for non-allowed-group user" do
      query = create_de_query
      shared =
        InsightsSharedReport.create!(
          user_id: admin.id,
          report_data: [{ "query_id" => query.id, "params" => {} }],
        )

      sign_in(user)
      get "/insights/shared-reports/#{shared.key}.json"
      expect(response.status).to eq(403)
    end

    context "with Data Explorer query access filtering" do
      fab!(:accessible_query) { create_de_query(name: "Accessible", groups: [group]) }
      fab!(:restricted_query) do
        other = Fabricate(:group)
        create_de_query(name: "Restricted", groups: [other])
      end

      fab!(:shared_report) do
        InsightsSharedReport.create!(
          user_id: admin.id,
          report_data: [
            { "query_id" => accessible_query.id, "params" => {} },
            { "query_id" => restricted_query.id, "params" => {} },
          ],
        )
      end

      before do
        SiteSetting.insights_allowed_groups = "#{Group::AUTO_GROUPS[:admins]}|#{group.id}"
      end

      it "admin sees all queries in the report" do
        sign_in(admin)
        get "/insights/shared-reports/#{shared_report.key}.json"

        names = response.parsed_body["reports"].map { |r| r["name"] }
        expect(names).to include("Accessible")
        expect(names).to include("Restricted")
      end

      it "non-admin viewer only sees queries their groups can access" do
        sign_in(member)
        get "/insights/shared-reports/#{shared_report.key}.json"

        names = response.parsed_body["reports"].map { |r| r["name"] }
        expect(names).to include("Accessible")
        expect(names).not_to include("Restricted")
      end

      it "viewer cannot run a query from the report they don't have group access to" do
        sign_in(member)

        get "/insights/reports/#{accessible_query.id}/run.json"
        expect(response.status).to eq(200)

        get "/insights/reports/#{restricted_query.id}/run.json"
        expect(response.status).to eq(404)
      end

      it "viewer with no query access sees empty reports array" do
        other_group = Fabricate(:group)
        no_access_group = Fabricate(:group)
        no_access_user = Fabricate(:user, groups: [no_access_group])
        SiteSetting.insights_allowed_groups =
          "#{Group::AUTO_GROUPS[:admins]}|#{group.id}|#{no_access_group.id}"

        # both queries require specific groups the user isn't in
        only_restricted =
          InsightsSharedReport.create!(
            user_id: admin.id,
            report_data: [
              { "query_id" => accessible_query.id, "params" => {} },
              { "query_id" => restricted_query.id, "params" => {} },
            ],
          )

        sign_in(no_access_user)
        get "/insights/shared-reports/#{only_restricted.key}.json"

        expect(response.parsed_body["reports"]).to be_empty
      end
    end
  end

  describe "#update" do
    it "denies access when not logged in" do
      query = create_de_query
      shared =
        InsightsSharedReport.create!(
          user_id: admin.id,
          report_data: [{ "query_id" => query.id, "params" => {} }],
        )

      put "/insights/shared-reports/#{shared.key}.json", params: { title: "Nope" }
      expect(response.status).to eq(403)
    end

    context "when logged in as the owner" do
      before { sign_in(admin) }

      it "updates title and report_data" do
        query1 = create_de_query(name: "Q1")
        query2 = create_de_query(name: "Q2")
        shared =
          InsightsSharedReport.create!(
            user_id: admin.id,
            report_data: [{ "query_id" => query1.id, "params" => {} }],
          )

        put "/insights/shared-reports/#{shared.key}.json",
            params: {
              title: "Updated Title",
              reports: [{ query_id: query2.id, params: { category_id: "5" } }],
            }
        expect(response.status).to eq(200)

        shared.reload
        expect(shared.title).to eq("Updated Title")
        expect(shared.report_data.length).to eq(1)
        expect(shared.report_data[0]["query_id"]).to eq(query2.id)
        expect(shared.report_data[0]["params"]).to eq({ "category_id" => "5" })
      end

      it "validates query access on new report_data" do
        other_group = Fabricate(:group)
        restricted = create_de_query(groups: [other_group])

        sign_in(member)
        SiteSetting.insights_allowed_groups = "#{Group::AUTO_GROUPS[:admins]}|#{group.id}"
        accessible = create_de_query(groups: [group])
        shared =
          InsightsSharedReport.create!(
            user_id: member.id,
            report_data: [{ "query_id" => accessible.id, "params" => {} }],
          )

        put "/insights/shared-reports/#{shared.key}.json",
            params: {
              reports: [{ query_id: restricted.id, params: {} }],
            }
        expect(response.status).to eq(404)
      end
    end

    context "when logged in as non-owner" do
      it "returns 403" do
        query = create_de_query
        shared =
          InsightsSharedReport.create!(
            user_id: admin.id,
            report_data: [{ "query_id" => query.id, "params" => {} }],
          )

        sign_in(member)
        SiteSetting.insights_allowed_groups = "#{Group::AUTO_GROUPS[:admins]}|#{group.id}"

        put "/insights/shared-reports/#{shared.key}.json", params: { title: "Hacked" }
        expect(response.status).to eq(403)
      end
    end
  end

  describe "#destroy" do
    it "denies access when not logged in" do
      query = create_de_query
      shared =
        InsightsSharedReport.create!(
          user_id: admin.id,
          report_data: [{ "query_id" => query.id, "params" => {} }],
        )

      delete "/insights/shared-reports/#{shared.key}.json"
      expect(response.status).to eq(403)
      expect(InsightsSharedReport.find_by(key: shared.key)).to be_present
    end

    context "when logged in as the owner" do
      before { sign_in(admin) }

      it "deletes the shared report" do
        query = create_de_query
        shared =
          InsightsSharedReport.create!(
            user_id: admin.id,
            report_data: [{ "query_id" => query.id, "params" => {} }],
          )

        delete "/insights/shared-reports/#{shared.key}.json"
        expect(response.status).to eq(200)
        expect(InsightsSharedReport.find_by(key: shared.key)).to be_nil
      end
    end

    context "when logged in as non-owner" do
      it "returns 403" do
        query = create_de_query
        shared =
          InsightsSharedReport.create!(
            user_id: admin.id,
            report_data: [{ "query_id" => query.id, "params" => {} }],
          )

        sign_in(member)
        SiteSetting.insights_allowed_groups = "#{Group::AUTO_GROUPS[:admins]}|#{group.id}"

        delete "/insights/shared-reports/#{shared.key}.json"
        expect(response.status).to eq(403)
      end
    end
  end
end
