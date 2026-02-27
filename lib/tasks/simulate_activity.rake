# frozen_string_literal: true

desc "Simulate 3 months of forum activity (~2000 posts/day) for admin dashboard graphs"
task "dev:simulate_activity" => :environment do
  unless Rails.env.development? || ENV["ALLOW_DEV_POPULATE"] == "1"
    raise "Run in development or set ALLOW_DEV_POPULATE=1"
  end

  require "faker"

  NUM_USERS = 500
  NUM_CATEGORIES = 20
  NUM_TAGS = 50
  DAYS = 90
  TARGET_POSTS_PER_DAY = 2000
  TOPICS_PER_DAY = 100

  start_date = DAYS.days.ago.beginning_of_day
  end_date = Time.current

  RateLimiter.disable

  puts "=== Dashboard Activity Simulator ==="
  puts "Period: #{start_date.to_date} to #{end_date.to_date} (#{DAYS} days)"
  puts "Target: ~#{TARGET_POSTS_PER_DAY} posts/day"
  puts "Expected: ~#{DAYS * TOPICS_PER_DAY} topics, ~#{DAYS * TARGET_POSTS_PER_DAY} posts"
  puts

  # ── Step 1: Users ──────────────────────────────────────────────────────
  existing_user_ids = User.real.where("id > 0").pluck(:id)
  user_ids = existing_user_ids.dup

  if user_ids.length < NUM_USERS
    to_create = NUM_USERS - user_ids.length
    puts "Creating #{to_create} users..."

    to_create.times do |i|
      created_at = start_date + rand(DAYS * 86_400).seconds
      username = "simuser_#{SecureRandom.alphanumeric(8).downcase}"
      user = User.new(
        username: username,
        email: "#{username}@simulator.invalid",
        name: Faker::Name.name,
        password: SecureRandom.hex(20),
        created_at: created_at,
        trust_level: rand(0..4),
        active: true,
        approved: true,
      )
      user.save!(validate: false)
      user_ids << user.id
      print "\r  Users: #{i + 1}/#{to_create}" if (i + 1) % 50 == 0
    end
    puts
  else
    puts "Already have #{user_ids.length} users, skipping creation."
  end

  # ── Step 2: Categories ─────────────────────────────────────────────────
  category_ids = Category.where("id > 0").where(parent_category_id: nil).pluck(:id)

  if category_ids.length < NUM_CATEGORIES
    to_create = NUM_CATEGORIES - category_ids.length
    puts "Creating #{to_create} categories..."
    to_create.times do
      name = "Sim #{Faker::Lorem.word.capitalize} #{SecureRandom.hex(3)}"
      cat = Category.new(
        name: name,
        slug: Slug.for(name).presence || "sim-#{SecureRandom.hex(4)}",
        user_id: Discourse::SYSTEM_USER_ID,
        color: "%06x" % rand(0xFFFFFF),
      )
      cat.save!(validate: false)
      category_ids << cat.id
    end
  else
    puts "Already have #{category_ids.length} categories, skipping creation."
  end

  # ── Step 3: Tags ───────────────────────────────────────────────────────
  tag_ids = []
  if SiteSetting.tagging_enabled
    tag_ids = Tag.pluck(:id)
    if tag_ids.length < NUM_TAGS
      to_create = NUM_TAGS - tag_ids.length
      puts "Creating #{to_create} tags..."
      to_create.times do
        tag = Tag.create(name: "sim-#{SecureRandom.hex(4)}")
        tag_ids << tag.id if tag.persisted?
      end
    else
      puts "Already have #{tag_ids.length} tags, skipping creation."
    end
  end

  # ── Step 4: Topics and Posts (bulk) ────────────────────────────────────
  puts "Creating topics and posts..."

  topic_post_counts = {}
  all_topic_ids = []
  total_posts = 0
  total_topics = 0

  DAYS.times do |day_offset|
    current_date = start_date + day_offset.days

    # Vary daily volume: weekdays busier than weekends
    weekday = current_date.wday.between?(1, 5)
    day_multiplier = weekday ? rand(0.9..1.3) : rand(0.4..0.7)
    day_topics = (TOPICS_PER_DAY * day_multiplier).to_i
    day_replies = ((TARGET_POSTS_PER_DAY - TOPICS_PER_DAY) * day_multiplier).to_i

    # ── Create topics ──
    topic_rows = []
    topic_meta = []

    day_topics.times do
      created_at = current_date + rand(0..86_399).seconds
      user_id = user_ids.sample
      category_id = category_ids.sample
      title = "#{Faker::Lorem.sentence(word_count: rand(5..10)).chomp('.')} #{SecureRandom.hex(3)}"
      title = title[0, SiteSetting.max_topic_title_length]

      raw = Faker::Lorem.paragraphs(number: rand(2..4)).join("\n\n")
      cooked = raw.split("\n\n").map { |p| "<p>#{CGI.escapeHTML(p)}</p>" }.join("\n")

      topic_rows << {
        title: title,
        fancy_title: title,
        slug: Slug.for(title).presence || "topic",
        user_id: user_id,
        last_post_user_id: user_id,
        category_id: category_id,
        archetype: "regular",
        created_at: created_at,
        updated_at: created_at,
        bumped_at: created_at,
        last_posted_at: created_at,
        posts_count: 1,
        highest_post_number: 1,
        views: rand(1..500),
        visible: true,
      }

      topic_meta << { user_id: user_id, raw: raw, cooked: cooked, created_at: created_at }
    end

    next if topic_rows.empty?

    inserted = Topic.insert_all(topic_rows, returning: %w[id])
    new_topic_ids = inserted.map { |r| r["id"] }

    # Opening posts for each topic
    op_rows = new_topic_ids.each_with_index.map do |tid, i|
      meta = topic_meta[i]
      topic_post_counts[tid] = 1
      {
        topic_id: tid,
        user_id: meta[:user_id],
        post_number: 1,
        sort_order: 1,
        raw: meta[:raw],
        cooked: meta[:cooked],
        created_at: meta[:created_at],
        updated_at: meta[:created_at],
        last_version_at: meta[:created_at],
        post_type: 1,
        word_count: meta[:raw].split.length,
      }
    end

    Post.insert_all(op_rows)
    all_topic_ids.concat(new_topic_ids)
    total_topics += new_topic_ids.length
    total_posts += op_rows.length

    # Tag some topics
    if tag_ids.any?
      tag_rows = []
      new_topic_ids.each do |tid|
        next if rand >= 0.4
        tag_ids.sample(rand(1..3)).each do |tag_id|
          tag_rows << { topic_id: tid, tag_id: tag_id }
        end
      end
      TopicTag.insert_all(tag_rows) if tag_rows.any?
    end

    # ── Create replies ──
    if all_topic_ids.any?
      # Weight toward recent topics
      reply_pool = if all_topic_ids.length > 1000
                     all_topic_ids.last(1000)
                   else
                     all_topic_ids
                   end

      reply_rows = []
      day_replies.times do
        created_at = current_date + rand(0..86_399).seconds
        user_id = user_ids.sample
        topic_id = reply_pool.sample

        topic_post_counts[topic_id] ||= 1
        topic_post_counts[topic_id] += 1
        pn = topic_post_counts[topic_id]

        raw = Faker::Lorem.paragraphs(number: rand(1..3)).join("\n\n")
        cooked = raw.split("\n\n").map { |p| "<p>#{CGI.escapeHTML(p)}</p>" }.join("\n")

        reply_rows << {
          topic_id: topic_id,
          user_id: user_id,
          post_number: pn,
          sort_order: pn,
          raw: raw,
          cooked: cooked,
          created_at: created_at,
          updated_at: created_at,
          last_version_at: created_at,
          post_type: 1,
          word_count: raw.split.length,
        }
      end

      reply_rows.each_slice(5_000) { |batch| Post.insert_all(batch) }
      total_posts += reply_rows.length
    end

    print "\r  Day #{day_offset + 1}/#{DAYS} | Topics: #{total_topics} | Posts: #{total_posts}"
  end
  puts

  # ── Step 5: Update topic statistics ────────────────────────────────────
  puts "Updating topic statistics..."
  all_topic_ids.each_slice(5_000) do |batch|
    ids = batch.join(",")
    DB.exec(<<~SQL)
      UPDATE topics SET
        posts_count = sub.cnt,
        highest_post_number = sub.max_pn,
        last_posted_at = sub.last_at,
        last_post_user_id = sub.last_uid,
        bumped_at = sub.last_at,
        updated_at = NOW()
      FROM (
        SELECT
          topic_id,
          COUNT(*) AS cnt,
          MAX(post_number) AS max_pn,
          MAX(created_at) AS last_at,
          (ARRAY_AGG(user_id ORDER BY created_at DESC))[1] AS last_uid
        FROM posts
        WHERE topic_id IN (#{ids}) AND deleted_at IS NULL
        GROUP BY topic_id
      ) sub
      WHERE topics.id = sub.topic_id
    SQL
  end

  # ── Step 6: Update user statistics ─────────────────────────────────────
  puts "Updating user statistics..."
  user_ids.each_slice(1_000) do |batch|
    ids = batch.join(",")
    DB.exec(<<~SQL)
      INSERT INTO user_stats (user_id, topic_count, post_count, first_post_created_at, new_since)
      SELECT
        u.id,
        COALESCE((SELECT COUNT(*) FROM topics WHERE topics.user_id = u.id AND topics.deleted_at IS NULL AND topics.archetype = 'regular'), 0),
        COALESCE((SELECT COUNT(*) FROM posts WHERE posts.user_id = u.id AND posts.deleted_at IS NULL), 0),
        (SELECT MIN(created_at) FROM posts WHERE posts.user_id = u.id AND posts.deleted_at IS NULL),
        u.created_at
      FROM users u
      WHERE u.id IN (#{ids})
      ON CONFLICT (user_id) DO UPDATE SET
        topic_count = EXCLUDED.topic_count,
        post_count = EXCLUDED.post_count,
        first_post_created_at = COALESCE(EXCLUDED.first_post_created_at, user_stats.first_post_created_at)
    SQL
  end

  # ── Step 7: User visits ────────────────────────────────────────────────
  puts "Creating user visit records..."
  visit_rows = []
  DAYS.times do |day_offset|
    date = (start_date + day_offset.days).to_date
    visiting_users = user_ids.sample(rand(150..350))
    visiting_users.each do |uid|
      visit_rows << {
        user_id: uid,
        visited_at: date,
        posts_read: rand(5..100),
        time_read: rand(300..7200),
      }
    end

    if visit_rows.length > 10_000
      UserVisit.insert_all(visit_rows) rescue nil
      visit_rows = []
    end
  end
  UserVisit.insert_all(visit_rows) rescue nil if visit_rows.any?

  # ── Step 8: Application requests (page views for site traffic graph) ──
  puts "Creating page view data..."
  DAYS.times do |day_offset|
    date = (start_date + day_offset.days).to_date
    weekday = date.wday.between?(1, 5)
    base = weekday ? rand(10_000..18_000) : rand(5_000..9_000)

    {
      http_total: base,
      http_2xx: (base * rand(0.88..0.95)).to_i,
      page_view_anon: (base * rand(0.30..0.45)).to_i,
      page_view_logged_in: (base * rand(0.25..0.35)).to_i,
      page_view_crawler: (base * rand(0.10..0.20)).to_i,
      page_view_anon_browser: (base * rand(0.20..0.35)).to_i,
      page_view_logged_in_browser: (base * rand(0.15..0.25)).to_i,
    }.each do |req_type, count|
      ApplicationRequest.write_cache!(req_type, count, date)
    end
  end

  puts
  puts "=== Simulation Complete ==="
  puts "Topics: #{total_topics}"
  puts "Posts:  #{total_posts}"
  puts "Users:  #{user_ids.length}"
  puts "Categories: #{category_ids.length}"
  puts "Tags:   #{tag_ids.length}"
ensure
  RateLimiter.enable
end
