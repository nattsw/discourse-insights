# frozen_string_literal: true

describe DiscourseInsights::FeedbackController do
  fab!(:admin)
  fab!(:user)

  before { enable_current_plugin }

  describe "#create" do
    context "when logged in as an admin" do
      before { sign_in(admin) }

      it "creates feedback" do
        post "/insights/feedback.json", params: { comment: "Great dashboard!" }
        expect(response.status).to eq(200)
        expect(response.parsed_body["success"]).to eq(true)

        feedback = InsightsFeedback.last
        expect(feedback.user_id).to eq(admin.id)
        expect(feedback.comment).to eq("Great dashboard!")
        expect(feedback.notified).to eq(false)
      end

      it "rejects blank comment" do
        post "/insights/feedback.json", params: { comment: "   " }
        expect(response.status).to eq(400)
      end

      it "rejects missing comment param" do
        post "/insights/feedback.json"
        expect(response.status).to eq(400)
      end

      it "rejects comments exceeding max length" do
        post "/insights/feedback.json", params: { comment: "a" * 10_001 }
        expect(response.status).to eq(422)
      end

      it "rate limits to 5 per day" do
        RateLimiter.enable

        5.times do |i|
          post "/insights/feedback.json", params: { comment: "Feedback #{i}" }
          expect(response.status).to eq(200)
        end

        post "/insights/feedback.json", params: { comment: "One too many" }
        expect(response.status).to eq(429)
      end
    end

    context "when logged in as a regular user not in allowed groups" do
      before { sign_in(user) }

      it "denies access" do
        post "/insights/feedback.json", params: { comment: "Feedback" }
        expect(response.status).to eq(403)
      end
    end

    context "when not logged in" do
      it "denies access" do
        post "/insights/feedback.json", params: { comment: "Feedback" }
        expect(response.status).to eq(403)
      end
    end

    context "when the plugin is disabled" do
      before do
        SiteSetting.insights_enabled = false
        sign_in(admin)
      end

      it "returns 404" do
        post "/insights/feedback.json", params: { comment: "Feedback" }
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

      it "creates feedback" do
        post "/insights/feedback.json", params: { comment: "Looks good!" }
        expect(response.status).to eq(200)
        expect(InsightsFeedback.last.user_id).to eq(member.id)
      end
    end
  end
end
