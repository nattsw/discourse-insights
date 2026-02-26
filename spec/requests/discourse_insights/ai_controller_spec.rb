# frozen_string_literal: true

describe DiscourseInsights::AiController do
  fab!(:admin)
  fab!(:user)

  before do
    enable_current_plugin

    skip("discourse-ai not available") unless defined?(DiscourseAi)
    SiteSetting.discourse_ai_enabled = true

    persona =
      AiPersona.find_or_create_by!(name: DiscourseInsights::AI_PERSONA_NAME) do |p|
        p.system_prompt = "test"
        p.allowed_group_ids = [Group::AUTO_GROUPS[:staff]]
      end
    llm = LlmModel.first || Fabricate(:llm_model)
    persona.update!(default_llm_id: llm.id)
  end

  describe "#generate" do
    context "when logged in as admin" do
      before { sign_in(admin) }

      it "enqueues a streaming job for a valid type" do
        expect_enqueued_with(
          job: :stream_insights_reply,
          args: {
            user_id: admin.id,
            type: "summary",
          },
        ) { post "/insights/ai/generate.json", params: { type: "summary" } }

        expect(response.status).to eq(200)
        expect(response.parsed_body["success"]).to eq(true)
      end

      it "rejects invalid type" do
        post "/insights/ai/generate.json", params: { type: "invalid" }
        expect(response.status).to eq(400)
      end

      it "requires a question for custom type" do
        post "/insights/ai/generate.json", params: { type: "custom" }
        expect(response.status).to eq(400)
      end

      it "accepts custom type with a question" do
        expect_enqueued_with(
          job: :stream_insights_reply,
          args: {
            user_id: admin.id,
            type: "custom",
            question: "How engaged are our users?",
          },
        ) do
          post "/insights/ai/generate.json",
               params: {
                 type: "custom",
                 question: "How engaged are our users?",
               }
        end

        expect(response.status).to eq(200)
      end

      it "passes period params to the job" do
        expect_enqueued_with(
          job: :stream_insights_reply,
          args: {
            user_id: admin.id,
            type: "summary",
            period_opts: {
              "period" => "7d",
            },
          },
        ) { post "/insights/ai/generate.json", params: { type: "summary", period: "7d" } }

        expect(response.status).to eq(200)
      end

      it "passes custom date range params to the job" do
        expect_enqueued_with(
          job: :stream_insights_reply,
          args: {
            user_id: admin.id,
            type: "summary",
            period_opts: {
              "start_date" => "2026-01-01",
              "end_date" => "2026-01-31",
            },
          },
        ) do
          post "/insights/ai/generate.json",
               params: {
                 type: "summary",
                 start_date: "2026-01-01",
                 end_date: "2026-01-31",
               }
        end

        expect(response.status).to eq(200)
      end
    end

    context "when logged in as a regular user not in allowed groups" do
      before { sign_in(user) }

      it "denies access" do
        post "/insights/ai/generate.json", params: { type: "summary" }
        expect(response.status).to eq(403)
      end
    end

    context "when not logged in" do
      it "denies access" do
        post "/insights/ai/generate.json", params: { type: "summary" }
        expect(response.status).to eq(403)
      end
    end
  end
end
