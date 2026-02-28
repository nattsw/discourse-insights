# frozen_string_literal: true

desc "Simulate 6 months of realistic forum activity for insights dashboard"
task "dev:simulate_activity" => :environment do
  # guard against double-execution (rake may load plugin task files twice)
  if defined?(@__simulate_activity_ran)
    puts "Skipping duplicate task execution"
    next
  end
  @__simulate_activity_ran = true

  unless Rails.env.development? || ENV["ALLOW_DEV_POPULATE"] == "1"
    raise "Run in development or set ALLOW_DEV_POPULATE=1"
  end

  require "faker"

  # calibrated against real large Discourse community dashboard metrics:
  #   7d:  ~3.3k visitors, 156k PV, 286 new members, 199 contributors, 1.4k posts, 2.8k likes, 80% response
  #   30d: ~14.7k visitors, 900k PV, 1.2k new members, 461 contributors, 6.2k posts, 11.4k likes, 86% response
  #   3m:  ~41.9k visitors, 2.2M PV, 3.4k new members, 844 contributors, 16.6k posts, 29.5k likes, 87% response
  num_users = 4500
  num_categories = 25
  num_tags = 80
  days = 180
  base_topics_per_day = 15
  base_replies_per_day = 170

  start_date = days.days.ago.beginning_of_day
  end_date = Time.current

  RateLimiter.disable

  puts "=== Dashboard Activity Simulator ==="
  puts "Period: #{start_date.to_date} to #{end_date.to_date} (#{days} days)"
  puts "Scale: ~#{num_users} users, ~#{base_topics_per_day + base_replies_per_day} posts/day growing to ~#{((base_topics_per_day + base_replies_per_day) * 1.3).to_i}"
  puts

  # ── Step 1: Users ──────────────────────────────────────────────────────
  existing_user_ids = User.real.where("id > 0").pluck(:id)
  user_ids = existing_user_ids.dup

  if user_ids.length < num_users
    to_create = num_users - user_ids.length
    puts "Creating #{to_create} users..."

    trust_levels = [0, 1, 1, 1, 1, 2, 2, 2, 3, 4]
    password_salt = "0" * 32
    password_hash =
      Pbkdf2.hash_password(
        SecureRandom.hex(20),
        password_salt,
        Rails.configuration.pbkdf2_iterations,
        Rails.configuration.pbkdf2_algorithm,
      )

    to_create
      .times
      .each_slice(500) do |batch|
        user_rows = []
        email_rows = []
        password_rows = []

        batch.each do |i|
          day_offset = (rand**0.5 * days).to_i
          created_at = start_date + day_offset.days + rand(0..86_399).seconds
          username = "simuser_#{SecureRandom.alphanumeric(8).downcase}"

          user_rows << {
            username: username,
            username_lower: username.downcase,
            name: Faker::Name.name,
            created_at: created_at,
            updated_at: created_at,
            trust_level: trust_levels.sample,
            active: true,
            approved: true,
          }
        end

        inserted = User.insert_all(user_rows, returning: %w[id username created_at])
        new_ids = inserted.map { |r| r["id"] }
        user_ids.concat(new_ids)

        inserted.each do |r|
          email_rows << {
            user_id: r["id"],
            email: "#{r["username"]}@simulator.invalid",
            primary: true,
            created_at: r["created_at"],
            updated_at: r["created_at"],
          }
          password_rows << {
            user_id: r["id"],
            password_hash: password_hash,
            password_salt: password_salt,
            password_algorithm:
              "$pbkdf2-#{Rails.configuration.pbkdf2_algorithm}$i=#{Rails.configuration.pbkdf2_iterations},l=32$",
            created_at: r["created_at"],
            updated_at: r["created_at"],
          }
        end
        UserEmail.insert_all(email_rows)
        UserPassword.insert_all(password_rows)

        print "\r  Users: #{user_ids.length - existing_user_ids.length}/#{to_create}"
      end
    puts
  else
    puts "Already have #{user_ids.length} users, skipping creation."
  end

  # poster distribution: 10 core posters make ~60% of posts,
  # 190 regular posters make ~37%, 3% from random users (occasional first-timers)
  # tight pool produces ~199 contributors/week matching target
  shuffled = user_ids.shuffle
  core_posters = shuffled[0...10]
  regular_posters = shuffled[10...200]
  weighted_poster_pool = (core_posters * 300) + regular_posters

  # ── Step 2: Categories ─────────────────────────────────────────────────
  category_names = %w[
    Support
    Bug
    Feature
    UX
    Dev
    Announcements
    Howto
    Marketplace
    Translations
    Hosting
    Plugin
    Themes
    API
    Documentation
    Community
  ]

  category_ids = Category.where("id > 0").where(parent_category_id: nil).pluck(:id)

  if category_ids.length < num_categories
    to_create = num_categories - category_ids.length
    puts "Creating #{to_create} categories..."
    to_create.times do |i|
      name =
        if i < category_names.length
          "#{category_names[i]} #{SecureRandom.hex(2)}"
        else
          "Sim #{Faker::Lorem.word.capitalize} #{SecureRandom.hex(3)}"
        end
      cat =
        Category.new(
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

  hot_categories = category_ids[0..5]
  cold_categories = category_ids[6..]
  weighted_category_pool = (hot_categories * 6) + (cold_categories || [])

  # ── Step 3: Tags ───────────────────────────────────────────────────────
  tag_ids = []
  if SiteSetting.tagging_enabled
    tag_ids = Tag.pluck(:id)
    if tag_ids.length < num_tags
      to_create = num_tags - tag_ids.length
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
  # pre-generate content pool to avoid ~36k Faker calls in inner loop
  paragraph_pool = 200.times.map { Faker::Lorem.paragraph(sentence_count: rand(3..8)) }
  title_pool = 300.times.map { Faker::Lorem.sentence(word_count: rand(5..12)).chomp(".") }

  make_raw = lambda { |n| n.times.map { paragraph_pool.sample }.join("\n\n") }
  make_cooked =
    lambda { |raw| raw.split("\n\n").map { |p| "<p>#{CGI.escapeHTML(p)}</p>" }.join("\n") }

  puts "Creating topics and posts..."

  topic_post_counts = {}
  all_topic_ids = []
  reply_eligible_ids = []
  total_posts = 0
  total_topics = 0

  days.times do |day_offset|
    current_date = start_date + day_offset.days

    # 30% growth over 6 months
    growth = 1.0 + (0.3 * day_offset.to_f / days)

    weekday = current_date.wday.between?(1, 5)
    day_multiplier = weekday ? rand(0.85..1.25) : rand(0.35..0.55)

    day_topics = (base_topics_per_day * day_multiplier * growth).to_i
    day_replies = (base_replies_per_day * day_multiplier * growth).to_i

    # ── Create topics ──
    topic_rows = []
    topic_meta = []

    day_topics.times do
      created_at = current_date + rand(0..86_399).seconds
      # 3% of posts from random users (occasional first-timers)
      user_id = rand < 0.03 ? user_ids.sample : weighted_poster_pool.sample
      category_id = weighted_category_pool.sample
      title = "#{title_pool.sample} #{SecureRandom.hex(3)}"[0, SiteSetting.max_topic_title_length]

      raw = make_raw.call(rand(1..5))
      cooked = make_cooked.call(raw)

      topic_rows << {
        title: title,
        fancy_title: title,
        slug: "topic-#{SecureRandom.hex(8)}",
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
        views: rand(5..2000),
        visible: true,
      }

      topic_meta << { user_id: user_id, raw: raw, cooked: cooked, created_at: created_at }
    end

    next if topic_rows.empty?

    inserted = Topic.insert_all(topic_rows, returning: %w[id])
    new_topic_ids = inserted.map { |r| r["id"] }

    op_rows =
      new_topic_ids.each_with_index.map do |tid, i|
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

    # ~85% of topics get replies (produces realistic response rate)
    reply_eligible_ids.concat(new_topic_ids.sample((new_topic_ids.length * 0.85).to_i))

    if tag_ids.any?
      tag_rows = []
      new_topic_ids.each do |tid|
        next if rand >= 0.4
        tag_ids.sample(rand(1..3)).each { |tag_id| tag_rows << { topic_id: tid, tag_id: tag_id } }
      end
      TopicTag.insert_all(tag_rows) if tag_rows.any?
    end

    # ── Create replies ──
    # first ensure unreplied eligible topics from last 3 days get a reply,
    # then distribute remaining replies randomly across the pool
    if reply_eligible_ids.any?
      # find unreplied eligible topics, prioritizing recent ones
      unreplied_all = reply_eligible_ids.select { |tid| topic_post_counts[tid] == 1 }
      # take up to half of daily replies as guaranteed first-replies
      unreplied = unreplied_all.last([unreplied_all.length, day_replies / 2].min)

      reply_pool =
        if reply_eligible_ids.length > 2000
          recent = reply_eligible_ids.last(1500)
          older = reply_eligible_ids[0...-1500].sample(500)
          recent + older
        else
          reply_eligible_ids
        end

      reply_rows = []
      replies_remaining = day_replies

      # guarantee first replies to unreplied topics
      unreplied.shuffle.each do |topic_id|
        break if replies_remaining <= 0
        created_at = current_date + rand(0..86_399).seconds
        user_id = rand < 0.03 ? user_ids.sample : weighted_poster_pool.sample

        topic_post_counts[topic_id] += 1
        pn = topic_post_counts[topic_id]

        raw = make_raw.call(rand(1..3))
        cooked = make_cooked.call(raw)

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
        replies_remaining -= 1
      end

      # distribute remaining replies randomly
      replies_remaining.times do
        created_at = current_date + rand(0..86_399).seconds
        user_id = rand < 0.03 ? user_ids.sample : weighted_poster_pool.sample
        topic_id = reply_pool.sample

        topic_post_counts[topic_id] ||= 1
        topic_post_counts[topic_id] += 1
        pn = topic_post_counts[topic_id]

        raw = make_raw.call(rand(1..3))
        cooked = make_cooked.call(raw)

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

    print "\r  Day #{day_offset + 1}/#{days} | Topics: #{total_topics} | Posts: #{total_posts}"
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

  # ── Step 5b: Reply to unreplied pre-existing topics ──────────────────
  # dev:populate topics in the simulation period may lack replies,
  # dragging down the overall response rate
  unreplied_preexisting = DB.query(<<~SQL)
    SELECT t.id, t.created_at
    FROM topics t
    WHERE t.archetype = 'regular'
      AND t.posts_count = 1
      AND t.created_at >= '#{start_date.to_date}'
      AND t.deleted_at IS NULL
      AND t.user_id NOT IN (SELECT id FROM users WHERE username LIKE 'simuser_%')
  SQL

  if unreplied_preexisting.any?
    # reply to 85% for realistic response rate
    to_reply = unreplied_preexisting.sample((unreplied_preexisting.length * 0.85).to_i)
    reply_rows = []
    to_reply.each do |topic|
      reply_at = topic.created_at + rand(1..72).hours
      reply_at = [reply_at, end_date].min
      raw = make_raw.call(rand(1..3))
      cooked = make_cooked.call(raw)

      reply_rows << {
        topic_id: topic.id,
        user_id: weighted_poster_pool.sample,
        post_number: 2,
        sort_order: 2,
        raw: raw,
        cooked: cooked,
        created_at: reply_at,
        updated_at: reply_at,
        last_version_at: reply_at,
        post_type: 1,
        word_count: raw.split.length,
      }
    end
    Post.insert_all(reply_rows) if reply_rows.any?

    # update topic stats for these
    ids = to_reply.map(&:id).join(",")
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
    puts "Added replies to #{reply_rows.length}/#{unreplied_preexisting.length} pre-existing unreplied topics"
  end

  # ── Step 5c: Solved topics ─────────────────────────────────────────────
  if defined?(::DiscourseSolved) &&
       ActiveRecord::Base.connection.table_exists?("discourse_solved_solved_topics")
    puts "Marking topics as solved..."

    # ~45% of replied sim topics get solved (realistic for support-heavy communities)
    # only sim topics — pre-existing dev:populate topics have clustered created_at
    replied_topics = DB.query(<<~SQL)
      SELECT t.id AS topic_id, t.user_id, t.created_at AS topic_created_at,
        (SELECT p.id FROM posts p WHERE p.topic_id = t.id AND p.post_number = 2 AND p.deleted_at IS NULL LIMIT 1) AS answer_post_id
      FROM topics t
      JOIN users u ON u.id = t.user_id AND u.username LIKE 'simuser_%'
      WHERE t.archetype = 'regular' AND t.posts_count > 1
        AND t.deleted_at IS NULL AND t.visible = true
        AND NOT EXISTS (SELECT 1 FROM discourse_solved_solved_topics s WHERE s.topic_id = t.id)
    SQL

    to_solve = replied_topics.select(&:answer_post_id).sample((replied_topics.length * 0.45).to_i)
    if to_solve.any?
      values =
        to_solve.map do |t|
          # solved shortly after topic creation (1-72 hours)
          solved_at = t.topic_created_at + rand(1..72).hours
          solved_at = [solved_at, end_date].min
          "(#{t.topic_id}, #{t.answer_post_id}, #{t.user_id}, '#{solved_at.utc.iso8601}', '#{solved_at.utc.iso8601}')"
        end
      values.each_slice(5_000) { |batch| DB.exec(<<~SQL) }
          INSERT INTO discourse_solved_solved_topics (topic_id, answer_post_id, accepter_user_id, created_at, updated_at)
          VALUES #{batch.join(",")}
          ON CONFLICT (topic_id) DO NOTHING
        SQL
      puts "  Marked #{to_solve.length} topics as solved"
    end
  end

  # ── Step 5d: Likes ─────────────────────────────────────────────────────
  # target: ~1.75 likes/post → matches ~2.8k likes on ~1.4k posts/week
  puts "Creating likes..."
  like_rows = []
  ua_rows = []
  total_likes = 0

  # only like posts from sim users (avoids inflating with pre-existing dev posts)
  flush_likes =
    lambda do
      begin
        PostAction.insert_all(like_rows)
      rescue StandardError
        nil
      end
      begin
        UserAction.insert_all(ua_rows)
      rescue StandardError
        nil
      end
      total_likes += like_rows.length
      like_rows = []
      ua_rows = []
      print "\r  Likes: #{total_likes}"
    end

  # process in batches to avoid loading all posts into memory
  sim_post_ids = DB.query_single(<<~SQL)
    SELECT p.id FROM posts p
    JOIN users u ON u.id = p.user_id
    WHERE u.username LIKE 'simuser_%' AND p.deleted_at IS NULL
    ORDER BY p.created_at
  SQL

  sim_post_ids.each_slice(5_000) do |id_batch|
    posts = DB.query(<<~SQL)
      SELECT id, user_id, topic_id, created_at::date AS day
      FROM posts WHERE id IN (#{id_batch.join(",")})
      ORDER BY created_at
    SQL

    posts.each do |post|
      next if rand >= 0.55

      num_likes =
        if rand < 0.04
          rand(8..20)
        elsif rand < 0.12
          rand(4..7)
        elsif rand < 0.35
          rand(2..3)
        else
          1
        end

      # rejection sampling: pick random users, skip if same as post author
      likers = []
      attempts = 0
      while likers.length < num_likes && attempts < num_likes * 3
        candidate = user_ids.sample
        likers << candidate if candidate != post.user_id && !likers.include?(candidate)
        attempts += 1
      end
      likers.each do |liker_id|
        delay_days = (rand**0.3 * 14).to_i
        liked_at = post.day.to_time + delay_days.days + rand(0..86_399).seconds
        next if liked_at > end_date # skip future-dated likes instead of clamping

        like_rows << {
          post_id: post.id,
          user_id: liker_id,
          post_action_type_id: PostActionType.types[:like],
          created_at: liked_at,
          updated_at: liked_at,
        }
        ua_rows << {
          action_type: 1,
          user_id: liker_id,
          target_topic_id: post.topic_id,
          target_post_id: post.id,
          acting_user_id: liker_id,
          created_at: liked_at,
          updated_at: liked_at,
        }
        ua_rows << {
          action_type: 2,
          user_id: post.user_id,
          target_topic_id: post.topic_id,
          target_post_id: post.id,
          acting_user_id: liker_id,
          created_at: liked_at,
          updated_at: liked_at,
        }
      end

      flush_likes.call if like_rows.length > 10_000
    end
  end

  flush_likes.call if like_rows.any?

  puts "\r  Created #{total_likes} likes, updating post like counts..."
  DB.exec(<<~SQL)
    UPDATE posts SET like_count = sub.cnt
    FROM (
      SELECT post_id, COUNT(*) AS cnt
      FROM post_actions
      WHERE post_action_type_id = #{PostActionType.types[:like]}
        AND deleted_at IS NULL
      GROUP BY post_id
    ) sub
    WHERE posts.id = sub.post_id
  SQL

  # ── Step 6: Update user statistics ─────────────────────────────────────
  puts "Updating user statistics..."
  like_type = PostActionType.types[:like]
  user_ids.each_slice(2_000) do |batch|
    ids = batch.join(",")
    DB.exec(<<~SQL)
      INSERT INTO user_stats (user_id, topic_count, post_count, first_post_created_at, new_since, likes_given, likes_received)
      SELECT
        u.id,
        COALESCE(tc.cnt, 0),
        COALESCE(pc.cnt, 0),
        pc.first_post,
        u.created_at,
        COALESCE(lg.cnt, 0),
        COALESCE(lr.cnt, 0)
      FROM users u
      LEFT JOIN (
        SELECT user_id, COUNT(*) AS cnt
        FROM topics WHERE deleted_at IS NULL AND archetype = 'regular'
        GROUP BY user_id
      ) tc ON tc.user_id = u.id
      LEFT JOIN (
        SELECT user_id, COUNT(*) AS cnt, MIN(created_at) AS first_post
        FROM posts WHERE deleted_at IS NULL
        GROUP BY user_id
      ) pc ON pc.user_id = u.id
      LEFT JOIN (
        SELECT user_id, COUNT(*) AS cnt
        FROM post_actions WHERE post_action_type_id = #{like_type} AND deleted_at IS NULL
        GROUP BY user_id
      ) lg ON lg.user_id = u.id
      LEFT JOIN (
        SELECT p.user_id, COUNT(*) AS cnt
        FROM post_actions pa JOIN posts p ON p.id = pa.post_id
        WHERE pa.post_action_type_id = #{like_type} AND pa.deleted_at IS NULL
        GROUP BY p.user_id
      ) lr ON lr.user_id = u.id
      WHERE u.id IN (#{ids})
      ON CONFLICT (user_id) DO UPDATE SET
        topic_count = EXCLUDED.topic_count,
        post_count = EXCLUDED.post_count,
        first_post_created_at = COALESCE(EXCLUDED.first_post_created_at, user_stats.first_post_created_at),
        likes_given = EXCLUDED.likes_given,
        likes_received = EXCLUDED.likes_received
    SQL
  end

  # ── Step 7: User visits ────────────────────────────────────────────────
  # ~450 DAU weekday, ~220 DAU weekend, growing 30%
  puts "Creating user visit records..."
  visit_rows = []
  days.times do |day_offset|
    date = (start_date + day_offset.days).to_date
    growth = 1.0 + (0.3 * day_offset.to_f / days)
    weekday = date.wday.between?(1, 5)
    base_visitors = weekday ? rand(380..520) : rand(160..280)
    num_visitors = (base_visitors * growth).to_i.clamp(1, user_ids.length)

    visiting_users = user_ids.sample(num_visitors)
    visiting_users.each do |uid|
      visit_rows << {
        user_id: uid,
        visited_at: date,
        posts_read: rand(5..200),
        time_read: rand(300..10_800),
      }
    end

    if visit_rows.length > 10_000
      begin
        UserVisit.insert_all(visit_rows)
      rescue StandardError
        nil
      end
      visit_rows = []
    end
  end
  if visit_rows.any?
    begin
      UserVisit.insert_all(visit_rows)
    rescue StandardError
      nil
    end
  end

  # ── Step 8: Application requests (page views) ─────────────────────────
  # dashboard uses page_view_anon_browser + page_view_logged_in_browser
  # target: ~24.5k combined weekday, ~12k weekend (base before growth)
  puts "Creating page view data..."
  days.times do |day_offset|
    date = (start_date + day_offset.days).to_date
    growth = 1.0 + (0.3 * day_offset.to_f / days)
    weekday = date.wday.between?(1, 5)

    pv_anon_browser = ((weekday ? rand(12_000..18_000) : rand(5_000..10_000)) * growth).to_i
    pv_logged_in_browser = ((weekday ? rand(7_000..12_000) : rand(3_000..6_000)) * growth).to_i
    total_browser = pv_anon_browser + pv_logged_in_browser

    {
      http_total: (total_browser * rand(2.5..3.5)).to_i,
      http_2xx: (total_browser * rand(2.2..3.0)).to_i,
      page_view_anon: (pv_anon_browser * rand(1.1..1.4)).to_i,
      page_view_logged_in: (pv_logged_in_browser * rand(1.1..1.3)).to_i,
      page_view_crawler: (total_browser * rand(0.15..0.30)).to_i,
      page_view_anon_browser: pv_anon_browser,
      page_view_logged_in_browser: pv_logged_in_browser,
    }.each { |req_type, count| ApplicationRequest.write_cache!(req_type, count, date) }
  end

  puts
  puts "=== Simulation Complete ==="
  puts "Topics:     #{total_topics}"
  puts "Posts:      #{total_posts}"
  puts "Likes:      #{total_likes}"
  puts "Users:      #{user_ids.length}"
  puts "Categories: #{category_ids.length}"
  puts "Tags:       #{tag_ids.length}"
  puts "Period:     #{start_date.to_date} to #{end_date.to_date}"
ensure
  RateLimiter.enable
end
