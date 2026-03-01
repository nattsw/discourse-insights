# frozen_string_literal: true

desc "Simulate recent activity for the Insights Live View (posts, likes, signups in the last few minutes)"
task "dev:insights_live_activity:simulate" => :environment do
  unless Rails.env.development? || ENV["ALLOW_DEV_POPULATE"] == "1"
    raise "Run in development or set ALLOW_DEV_POPULATE=1"
  end

  RateLimiter.disable

  puts "=== Live Activity Simulator ==="

  user_ids = User.real.where("id > 0").pluck(:id)
  if user_ids.length < 5
    puts "Need at least 5 users. Run dev:insights_activity:simulate first or create some users."
    next
  end

  categories =
    Category.where(read_restricted: false).where("id > 0").where(parent_category_id: nil).limit(6)
  if categories.empty?
    puts "No public categories found."
    next
  end

  # clear live cache so results show immediately
  Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)

  # ── Mark users as recently active ──────────────────────────────────
  active_count = [user_ids.length, rand(8..25)].min
  active_ids = user_ids.sample(active_count)
  active_ids.each { |uid| User.where(id: uid).update_all(last_seen_at: rand(1..240).seconds.ago) }
  puts "  Marked #{active_count} users as active (last_seen_at in last 4 min)"

  # ── Create recent posts across categories ──────────────────────────
  titles = [
    "Getting started with custom themes",
    "Issue with SSO authentication flow",
    "Feature request: dark mode for mobile",
    "How to migrate from another platform",
    "Performance tips for large communities",
    "Best practices for category organization",
    "Plugin compatibility after upgrade",
    "Webhook integration with Slack",
    "Custom user fields not showing",
    "Search results not returning expected topics",
    "Email notifications not sending",
    "Embedding Discourse comments on blog",
    "Setting up backup schedule",
    "User trust level progression",
    "API rate limiting questions",
  ]

  post_count = 0
  topic_ids = []

  categories.each do |cat|
    num_topics = rand(1..3)
    num_topics.times do
      minutes_ago = rand(1..9)
      created_at = minutes_ago.minutes.ago
      author = user_ids.sample
      title = "#{titles.sample} #{SecureRandom.hex(3)}"

      topic =
        Topic.create!(
          title: title,
          user_id: author,
          category_id: cat.id,
          archetype: "regular",
          created_at: created_at,
          bumped_at: created_at,
          last_posted_at: created_at,
          last_post_user_id: author,
        )

      Post.create!(
        topic_id: topic.id,
        user_id: author,
        post_number: 1,
        sort_order: 1,
        raw: "This is a simulated post for Live View testing. #{SecureRandom.hex(8)}",
        created_at: created_at,
      )

      topic_ids << topic.id
      post_count += 1

      # add 1-3 replies to some topics
      if rand < 0.6
        rand(1..3).times do |i|
          reply_minutes = [minutes_ago - rand(1..minutes_ago.clamp(1, 8)), 0].max
          reply_at = reply_minutes.minutes.ago
          replier = (user_ids - [author]).sample

          Post.create!(
            topic_id: topic.id,
            user_id: replier,
            post_number: i + 2,
            sort_order: i + 2,
            raw: "Reply to the topic. #{SecureRandom.hex(8)}",
            created_at: reply_at,
          )
          post_count += 1
        end

        topic.reload
        topic.update_columns(
          posts_count: topic.posts.count,
          highest_post_number: topic.posts.maximum(:post_number),
          last_posted_at: topic.posts.maximum(:created_at),
        )
      end
    end
  end
  puts "  Created #{post_count} posts across #{topic_ids.length} topics in #{categories.length} categories"

  # ── Create recent likes ────────────────────────────────────────────
  recent_posts =
    Post
      .joins(:topic)
      .joins("JOIN categories c ON c.id = topics.category_id")
      .where("posts.created_at > ?", 10.minutes.ago)
      .where("topics.archetype = 'regular'")
      .where("c.read_restricted = false")
      .where("posts.deleted_at IS NULL")
      .pluck(:id, :user_id, :topic_id)

  like_count = 0
  recent_posts
    .sample([recent_posts.length, 10].min)
    .each do |post_id, post_user_id, topic_id|
      likers = (user_ids - [post_user_id]).sample(rand(1..4))
      likers.each do |liker_id|
        liked_at = rand(1..8).minutes.ago
        begin
          PostAction.create!(
            post_id: post_id,
            user_id: liker_id,
            post_action_type_id: PostActionType.types[:like],
            created_at: liked_at,
          )
          UserAction.create!(
            action_type: UserAction::LIKE,
            user_id: liker_id,
            target_topic_id: topic_id,
            target_post_id: post_id,
            acting_user_id: liker_id,
            created_at: liked_at,
          )
          like_count += 1
        rescue ActiveRecord::RecordNotUnique
          next
        end
      end
    end
  puts "  Created #{like_count} likes"

  # ── Create recent signups ──────────────────────────────────────────
  signup_count = rand(1..3)
  signup_count.times do |i|
    username = "newbie_#{SecureRandom.alphanumeric(6).downcase}"
    created_at = rand(1..8).minutes.ago
    user =
      User.create!(
        username: username,
        email: "#{username}@insights-live-simulator.invalid",
        password: SecureRandom.hex(20),
        trust_level: 0,
        active: true,
        approved: true,
        created_at: created_at,
      )
  end
  puts "  Created #{signup_count} new users"

  # clear cache again after all data is in
  Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)

  puts
  puts "=== Done! Refresh the Live View on /insights ==="
  puts "  Active users: #{active_count}"
  puts "  Posts: #{post_count} in #{topic_ids.length} topics"
  puts "  Likes: #{like_count}"
  puts "  Signups: #{signup_count}"
ensure
  RateLimiter.enable
end
