# frozen_string_literal: true

module ::DiscourseInsights
  class LiveController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    include DiscourseInsights::AccessControl

    before_action :ensure_logged_in
    before_action :ensure_allowed

    CACHE_KEY = "insights_live"
    CACHE_TTL = 25.seconds
    ACTIVE_THRESHOLD = 5.minutes
    MAX_GROUPED_ITEMS = 10
    MAX_HOT_CATEGORIES = 5
    MAX_HOT_CHAT_CHANNELS = 5

    # activity tiers: [min_posts_per_hour, stream_window, categories_window, chat_window]
    ACTIVITY_TIERS = [
      { min_posts: 20, stream: 10.minutes, categories: 1.hour, chat: 30.minutes },
      { min_posts: 5, stream: 1.hour, categories: 4.hours, chat: 2.hours },
      { min_posts: 1, stream: 4.hours, categories: 12.hours, chat: 8.hours },
      { min_posts: 0, stream: 24.hours, categories: 24.hours, chat: 24.hours },
    ]

    def show
      data = Discourse.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { compute }
      render json: data
    end

    private

    def compute
      tier = detect_activity_tier

      result = {
        active_users: compute_active_users,
        composing: compute_composing,
        hot_categories: compute_hot_categories(tier[:categories]),
        activity_stream: compute_activity_stream(tier[:stream]),
        windows: {
          stream_minutes: (tier[:stream] / 60).to_i,
          categories_minutes: (tier[:categories] / 60).to_i,
          chat_minutes: (tier[:chat] / 60).to_i,
        },
      }
      result[:hot_chat_channels] = compute_hot_chat_channels(tier[:chat]) if chat_enabled?
      result
    end

    def detect_activity_tier
      recent_posts =
        DB.query_single(<<~SQL).first
          SELECT COUNT(*)
          FROM posts p
          JOIN topics t ON t.id = p.topic_id
          WHERE p.created_at > NOW() - INTERVAL '1 hour'
            AND p.deleted_at IS NULL
            AND t.deleted_at IS NULL
            AND t.visible = true
            AND p.post_type = 1
            AND p.hidden = false
        SQL

      ACTIVITY_TIERS.find { |t| recent_posts >= t[:min_posts] }
    end

    def compute_active_users
      User
        .where("last_seen_at > ?", ACTIVE_THRESHOLD.ago)
        .where("id > 0")
        .not_suspended
        .not_silenced
        .count
    end

    def compute_composing
      topic_replies = 0
      chat_replies = 0

      begin
        redis = PresenceChannel.redis
        channels_key = Discourse.redis.namespace_key("_presence_channels")
        all_channels = redis.zrangebyscore(channels_key, "-inf", "+inf")

        # collect topic/channel IDs from active presence channels
        topic_channels = {}
        chat_channel_counts = {}

        all_channels.each do |channel_name|
          hash_key = Discourse.redis.namespace_key("_presence_#{channel_name}_hash")
          count = redis.hlen(hash_key)
          next if count == 0

          # exclude whispers — staff-only, shouldn't appear in shared cache
          if channel_name.start_with?("/discourse-presence/reply/")
            topic_id = channel_name.split("/").last.to_i
            topic_channels[topic_id] = (topic_channels[topic_id] || 0) + count
          elsif channel_name.start_with?("/chat-reply/")
            ch_id = channel_name.split("/").last.to_i
            chat_channel_counts[ch_id] = (chat_channel_counts[ch_id] || 0) + count
          end
        end

        # only count composing in public topics
        if topic_channels.any?
          public_topic_ids = DB.query_single(<<~SQL, ids: topic_channels.keys)
              SELECT t.id FROM topics t
              JOIN categories c ON c.id = t.category_id
              WHERE t.id IN (:ids)
                AND c.read_restricted = false
                AND t.archetype = 'regular'
            SQL
          public_topic_ids.each { |tid| topic_replies += topic_channels[tid] }
        end

        # only count composing in public chat channels
        if chat_channel_counts.any? && chat_enabled?
          public_channel_ids = DB.query_single(<<~SQL, ids: chat_channel_counts.keys)
              SELECT cc.id FROM chat_channels cc
              JOIN categories c ON c.id = cc.chatable_id AND cc.chatable_type = 'Category'
              WHERE cc.id IN (:ids)
                AND c.read_restricted = false
            SQL
          public_channel_ids.each { |cid| chat_replies += chat_channel_counts[cid] }
        end
      rescue StandardError
        # redis unavailable or presence not configured — return zeros
      end

      { topic_replies: topic_replies, chat: chat_replies, total: topic_replies + chat_replies }
    end

    def compute_hot_categories(window)
      DB
        .query(<<~SQL, window: window.ago, limit: MAX_HOT_CATEGORIES)
          SELECT c.id AS category_id, c.name, c.color, COUNT(*) AS recent_posts
          FROM posts p
          JOIN topics t ON t.id = p.topic_id
          JOIN categories c ON c.id = t.category_id
          JOIN users u ON u.id = p.user_id
          WHERE p.created_at > :window
            AND p.deleted_at IS NULL
            AND t.deleted_at IS NULL
            AND t.visible = true
            AND t.archetype = 'regular'
            AND c.read_restricted = false
            AND p.post_type = 1
            AND p.hidden = false
            AND (u.suspended_till IS NULL OR u.suspended_till <= NOW())
            AND (u.silenced_till IS NULL OR u.silenced_till <= NOW())
          GROUP BY c.id, c.name, c.color
          ORDER BY recent_posts DESC
          LIMIT :limit
        SQL
        .map do |row|
          {
            category_id: row.category_id,
            name: row.name,
            color: row.color,
            recent_posts: row.recent_posts,
          }
        end
    end

    def compute_activity_stream(window)
      cutoff = window.ago
      posts_by_topic = {}

      # recent posts — fetch more for grouping headroom
      DB
        .query(<<~SQL, cutoff:)
        SELECT p.id, p.user_id, u.username, t.id AS topic_id, t.title AS topic_title,
               t.category_id, p.created_at, p.post_number
        FROM posts p
        JOIN topics t ON t.id = p.topic_id
        JOIN users u ON u.id = p.user_id
        JOIN categories c ON c.id = t.category_id
        WHERE p.created_at > :cutoff
          AND p.deleted_at IS NULL
          AND t.deleted_at IS NULL
          AND t.visible = true
          AND t.archetype = 'regular'
          AND c.read_restricted = false
          AND p.post_type = 1
          AND p.hidden = false
          AND u.id > 0
          AND (u.suspended_till IS NULL OR u.suspended_till <= NOW())
          AND (u.silenced_till IS NULL OR u.silenced_till <= NOW())
        ORDER BY p.created_at DESC
        LIMIT 50
      SQL
        .each do |row|
          entry = posts_by_topic[row.topic_id]
          if entry
            if row.post_number == 1
              entry[:is_new] = true
            else
              entry[:replies] += 1
            end
            entry[:created_at] = [entry[:created_at], row.created_at].max
          else
            posts_by_topic[row.topic_id] = {
              topic_id: row.topic_id,
              topic_title: row.topic_title,
              category_id: row.category_id,
              replies: row.post_number == 1 ? 0 : 1,
              likes: 0,
              is_new: row.post_number == 1,
              created_at: row.created_at,
            }
          end
        end

      # recent likes — merge into existing topic entries only
      DB
        .query(<<~SQL, cutoff:)
        SELECT p.topic_id, ua.created_at
        FROM user_actions ua
        JOIN users u ON u.id = ua.user_id
        JOIN posts p ON p.id = ua.target_post_id
        JOIN topics t ON t.id = p.topic_id
        JOIN categories c ON c.id = t.category_id
        WHERE ua.created_at > :cutoff
          AND ua.action_type = 1
          AND t.deleted_at IS NULL
          AND t.visible = true
          AND t.archetype = 'regular'
          AND c.read_restricted = false
          AND p.hidden = false
          AND u.id > 0
          AND (u.suspended_till IS NULL OR u.suspended_till <= NOW())
          AND (u.silenced_till IS NULL OR u.silenced_till <= NOW())
        ORDER BY ua.created_at DESC
        LIMIT 30
      SQL
        .each do |row|
          entry = posts_by_topic[row.topic_id]
          next unless entry
          entry[:likes] += 1
          entry[:created_at] = [entry[:created_at], row.created_at].max
        end

      # build topic_activity items
      items =
        posts_by_topic.values.map do |entry|
          {
            type: "topic_activity",
            topic_id: entry[:topic_id],
            topic_title: entry[:topic_title],
            category_id: entry[:category_id],
            replies: entry[:replies],
            likes: entry[:likes],
            is_new: entry[:is_new],
            created_at: entry[:created_at],
          }
        end

      # recent signups
      signups =
        User
          .real
          .activated
          .not_suspended
          .not_silenced
          .where("users.created_at > ?", cutoff)
          .order(created_at: :desc)
          .limit(10)
          .pluck(:username, :created_at)

      if signups.length > 1
        items << {
          type: "new_users",
          count: signups.length,
          usernames: signups.map(&:first),
          created_at: signups.first.last,
        }
      elsif signups.length == 1
        items << { type: "new_user", username: signups.first.first, created_at: signups.first.last }
      end

      # recent solved topics (if plugin available)
      if ActiveRecord::Base.connection.table_exists?("discourse_solved_solved_topics")
        DB
          .query(<<~SQL, cutoff:)
          SELECT st.topic_id, t.title AS topic_title, t.category_id,
                 st.accepter_user_id AS user_id, u.username, st.created_at
          FROM discourse_solved_solved_topics st
          JOIN topics t ON t.id = st.topic_id
          JOIN categories c ON c.id = t.category_id
          JOIN users u ON u.id = st.accepter_user_id
          WHERE st.created_at > :cutoff
            AND t.deleted_at IS NULL
            AND t.visible = true
            AND t.archetype = 'regular'
            AND c.read_restricted = false
            AND u.id > 0
            AND (u.suspended_till IS NULL OR u.suspended_till <= NOW())
            AND (u.silenced_till IS NULL OR u.silenced_till <= NOW())
          ORDER BY st.created_at DESC
          LIMIT 5
        SQL
          .each do |row|
            items << {
              type: "solved",
              user_id: row.user_id,
              username: row.username,
              topic_id: row.topic_id,
              topic_title: row.topic_title,
              category_id: row.category_id,
              created_at: row.created_at,
            }
          end
      end

      items
        .sort_by { |i| i[:created_at] }
        .reverse
        .first(MAX_GROUPED_ITEMS)
        .map do |item|
          item[:created_at] = item[:created_at].iso8601
          item
        end
    end

    def chat_enabled?
      defined?(::Chat) && ActiveRecord::Base.connection.table_exists?("chat_messages")
    end

    def compute_hot_chat_channels(window)
      DB
        .query(<<~SQL, window: window.ago, limit: MAX_HOT_CHAT_CHANNELS)
          SELECT cc.id AS channel_id, cc.name, c.color, cc.slug, COUNT(*) AS recent_messages
          FROM chat_messages cm
          JOIN chat_channels cc ON cc.id = cm.chat_channel_id
          JOIN categories c ON c.id = cc.chatable_id AND cc.chatable_type = 'Category'
          JOIN users u ON u.id = cm.user_id
          WHERE cm.created_at > :window
            AND cm.deleted_at IS NULL
            AND cc.deleted_at IS NULL
            AND cc.status = 0
            AND c.read_restricted = false
            AND u.id > 0
            AND (u.suspended_till IS NULL OR u.suspended_till <= NOW())
            AND (u.silenced_till IS NULL OR u.silenced_till <= NOW())
          GROUP BY cc.id, cc.name, c.color, cc.slug
          ORDER BY recent_messages DESC
          LIMIT :limit
        SQL
        .map do |row|
          {
            channel_id: row.channel_id,
            name: row.name,
            color: row.color,
            slug: row.slug,
            recent_messages: row.recent_messages,
          }
        end
    end
  end
end
