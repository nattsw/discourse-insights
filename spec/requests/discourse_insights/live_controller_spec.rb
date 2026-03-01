# frozen_string_literal: true

describe DiscourseInsights::LiveController do
  fab!(:admin)
  fab!(:user)

  before { enable_current_plugin }

  describe "#show" do
    context "when logged in as an admin" do
      before { sign_in(admin) }

      it "returns live data with expected keys" do
        get "/insights/live.json"
        expect(response.status).to eq(200)
        body = response.parsed_body
        expect(body).to have_key("active_users")
        expect(body).to have_key("composing")
        expect(body).to have_key("hot_categories")
        expect(body).to have_key("activity_stream")
      end

      it "returns composing counts" do
        get "/insights/live.json"
        composing = response.parsed_body["composing"]
        expect(composing).to have_key("topic_replies")
        expect(composing).to have_key("chat")
        expect(composing).to have_key("total")
      end

      it "includes recent posts in the activity stream" do
        topic = Fabricate(:topic)
        Fabricate(:post, topic: topic, user: admin)

        Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
        get "/insights/live.json"
        stream = response.parsed_body["activity_stream"]
        expect(stream).to be_an(Array)
      end

      it "only includes public category content in the stream" do
        restricted_category = Fabricate(:private_category, group: Group[:admins])
        restricted_topic = Fabricate(:topic, category: restricted_category)
        Fabricate(:post, topic: restricted_topic, user: admin)

        public_topic = Fabricate(:topic)
        Fabricate(:post, topic: public_topic, user: admin)

        Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
        get "/insights/live.json"
        stream = response.parsed_body["activity_stream"]
        topic_ids = stream.select { |i| i["topic_id"] }.map { |i| i["topic_id"] }
        expect(topic_ids).not_to include(restricted_topic.id)
      end

      it "excludes PMs from the activity stream" do
        pm = Fabricate(:private_message_topic, user: admin)
        Fabricate(:post, topic: pm, user: admin)

        Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
        get "/insights/live.json"
        stream = response.parsed_body["activity_stream"]
        topic_ids = stream.select { |i| i["topic_id"] }.map { |i| i["topic_id"] }
        expect(topic_ids).not_to include(pm.id)
      end

      it "counts active users" do
        admin.update!(last_seen_at: 1.minute.ago)

        Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
        get "/insights/live.json"
        expect(response.parsed_body["active_users"]).to be >= 1
      end

      it "returns hot categories from recent posts" do
        category = Fabricate(:category)
        topic = Fabricate(:topic, category: category)
        Fabricate(:post, topic: topic, user: admin)

        Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
        get "/insights/live.json"
        hot = response.parsed_body["hot_categories"]
        expect(hot).to be_an(Array)
      end

      it "caches the response" do
        get "/insights/live.json"
        first_response = response.parsed_body

        get "/insights/live.json"
        expect(response.parsed_body).to eq(first_response)
      end

      it "excludes hidden posts from activity stream" do
        topic = Fabricate(:topic)
        Fabricate(:post, topic: topic, user: admin, hidden: true)

        Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
        get "/insights/live.json"
        stream = response.parsed_body["activity_stream"]
        topic_ids = stream.select { |i| i["topic_id"] }.map { |i| i["topic_id"] }
        expect(topic_ids).not_to include(topic.id)
      end

      it "excludes suspended users' posts from activity stream" do
        suspended_user = Fabricate(:user, suspended_till: 1.year.from_now)
        topic = Fabricate(:topic)
        Fabricate(:post, topic: topic, user: suspended_user)

        Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
        get "/insights/live.json"
        stream = response.parsed_body["activity_stream"]
        topic_ids = stream.select { |i| i["topic_id"] }.map { |i| i["topic_id"] }
        expect(topic_ids).not_to include(topic.id)
      end

      it "excludes silenced users' posts from activity stream" do
        silenced_user = Fabricate(:user, silenced_till: 1.year.from_now)
        topic = Fabricate(:topic)
        Fabricate(:post, topic: topic, user: silenced_user)

        Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
        get "/insights/live.json"
        stream = response.parsed_body["activity_stream"]
        topic_ids = stream.select { |i| i["topic_id"] }.map { |i| i["topic_id"] }
        expect(topic_ids).not_to include(topic.id)
      end

      it "excludes suspended and silenced users from signups" do
        Fabricate(:user, suspended_till: 1.year.from_now)
        Fabricate(:user, silenced_till: 1.year.from_now)
        normal_user = Fabricate(:user)

        Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
        get "/insights/live.json"
        stream = response.parsed_body["activity_stream"]
        signup_items = stream.select { |i| i["type"] == "new_user" || i["type"] == "new_users" }
        all_usernames = signup_items.flat_map { |i| i["usernames"] || [i["username"]] }.compact
        expect(all_usernames).to include(normal_user.username)
        expect(all_usernames).not_to include(
          User.where("suspended_till > ?", Time.zone.now).pick(:username),
        )
      end

      it "excludes suspended users from active users count" do
        suspended_user =
          Fabricate(:user, suspended_till: 1.year.from_now, last_seen_at: 1.minute.ago)
        admin.update!(last_seen_at: 1.minute.ago)

        Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
        get "/insights/live.json"
        count = response.parsed_body["active_users"]

        admin_counted =
          User
            .where("last_seen_at > ?", 5.minutes.ago)
            .where("id > 0")
            .not_suspended
            .not_silenced
            .count
        expect(count).to eq(admin_counted)
      end

      it "groups activity by topic" do
        topic = Fabricate(:topic)
        Fabricate(:post, topic: topic, user: admin, post_number: 1)
        Fabricate(:post, topic: topic, user: Fabricate(:user), post_number: 2)
        Fabricate(:post, topic: topic, user: Fabricate(:user), post_number: 3)

        Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
        get "/insights/live.json"
        stream = response.parsed_body["activity_stream"]
        topic_items = stream.select { |i| i["topic_id"] == topic.id }
        expect(topic_items.length).to eq(1)
        expect(topic_items.first["type"]).to eq("topic_activity")
        expect(topic_items.first["replies"]).to eq(2)
        expect(topic_items.first["is_new"]).to eq(true)
      end

      it "collapses multiple signups into a single new_users item" do
        users = 3.times.map { Fabricate(:user) }

        Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
        get "/insights/live.json"
        stream = response.parsed_body["activity_stream"]
        grouped = stream.select { |i| i["type"] == "new_users" }
        expect(grouped.length).to eq(1)
        expect(grouped.first["count"]).to be >= 3
        expect(grouped.first["usernames"]).to include(*users.map(&:username))
      end

      it "respects MAX_GROUPED_ITEMS limit" do
        15.times do |n|
          topic = Fabricate(:topic)
          Fabricate(:post, topic: topic, user: admin)
        end

        Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
        get "/insights/live.json"
        stream = response.parsed_body["activity_stream"]
        expect(stream.length).to be <= 10
      end

      context "with chat plugin" do
        before { skip("Chat plugin not loaded") unless defined?(::Chat) }

        it "returns hot chat channels with recent messages" do
          category = Fabricate(:category)
          channel =
            Fabricate(:chat_channel, chatable: category, name: "General Chat", status: :open)
          Fabricate(:chat_message, chat_channel: channel, user: admin)
          Fabricate(:chat_message, chat_channel: channel, user: admin)

          Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
          get "/insights/live.json"
          hot_chat = response.parsed_body["hot_chat_channels"]
          expect(hot_chat).to be_an(Array)
          expect(hot_chat.length).to eq(1)
          expect(hot_chat.first["name"]).to eq("General Chat")
          expect(hot_chat.first["recent_messages"]).to eq(2)
          expect(hot_chat.first["color"]).to eq(category.color)
        end

        it "excludes DM channels from hot chat" do
          dm_channel = Fabricate(:direct_message_channel)
          Fabricate(:chat_message, chat_channel: dm_channel, user: admin)

          category = Fabricate(:category)
          public_channel = Fabricate(:chat_channel, chatable: category, status: :open)
          Fabricate(:chat_message, chat_channel: public_channel, user: admin)

          Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
          get "/insights/live.json"
          hot_chat = response.parsed_body["hot_chat_channels"]
          channel_ids = hot_chat.map { |c| c["channel_id"] }
          expect(channel_ids).not_to include(dm_channel.id)
          expect(channel_ids).to include(public_channel.id)
        end

        it "excludes messages from suspended users in hot chat" do
          suspended_user = Fabricate(:user, suspended_till: 1.year.from_now)
          category = Fabricate(:category)
          channel = Fabricate(:chat_channel, chatable: category, status: :open)
          Fabricate(:chat_message, chat_channel: channel, user: suspended_user)

          Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
          get "/insights/live.json"
          hot_chat = response.parsed_body["hot_chat_channels"]
          expect(hot_chat).to be_empty
        end

        it "does not return hot_chat_channels when chat is not available" do
          allow_any_instance_of(DiscourseInsights::LiveController).to receive(
            :chat_enabled?,
          ).and_return(false)

          Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
          get "/insights/live.json"
          expect(response.parsed_body).not_to have_key("hot_chat_channels")
        end
      end
    end

    context "when logged in as a regular user not in allowed groups" do
      before { sign_in(user) }

      it "denies access" do
        get "/insights/live.json"
        expect(response.status).to eq(403)
      end
    end

    context "when not logged in" do
      it "denies access" do
        get "/insights/live.json"
        expect(response.status).to eq(403)
      end
    end

    context "when the plugin is disabled" do
      before do
        SiteSetting.insights_enabled = false
        sign_in(admin)
      end

      it "returns 404" do
        get "/insights/live.json"
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
        get "/insights/live.json"
        expect(response.status).to eq(200)
      end
    end
  end
end
