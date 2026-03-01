# frozen_string_literal: true

desc "Remove all simulated activity created by dev:insights_live_activity:simulate"
task "dev:insights_live_activity:remove" => :environment do
  unless Rails.env.development? || ENV["ALLOW_DEV_POPULATE"] == "1"
    raise "Run in development or set ALLOW_DEV_POPULATE=1"
  end

  puts "=== Remove Simulated Activity ==="

  sim_user_ids = DB.query_single(<<~SQL)
      SELECT u.id FROM users u
      JOIN user_emails ue ON ue.user_id = u.id AND ue.primary = true
      WHERE ue.email LIKE '%@insights-live-simulator.invalid'
    SQL

  if sim_user_ids.empty?
    puts "No simulated users found. Nothing to clean up."
    next
  end

  puts "Found #{sim_user_ids.length} simulated users"

  sim_user_ids.each_slice(1_000) do |batch|
    ids = batch.join(",")

    # likes given by simulated users
    like_count =
      DB.query_single("SELECT COUNT(*) FROM post_actions WHERE user_id IN (#{ids})").first
    DB.exec("DELETE FROM post_actions WHERE user_id IN (#{ids})")
    DB.exec("DELETE FROM user_actions WHERE user_id IN (#{ids})")
    DB.exec("DELETE FROM user_actions WHERE acting_user_id IN (#{ids})")

    # likes received by simulated users' posts
    DB.exec(<<~SQL)
      DELETE FROM post_actions WHERE post_id IN (
        SELECT id FROM posts WHERE user_id IN (#{ids})
      )
    SQL
    DB.exec(<<~SQL)
      DELETE FROM user_actions WHERE target_post_id IN (
        SELECT id FROM posts WHERE user_id IN (#{ids})
      )
    SQL

    # posts by simulated users
    post_count = DB.query_single("SELECT COUNT(*) FROM posts WHERE user_id IN (#{ids})").first
    DB.exec("DELETE FROM posts WHERE user_id IN (#{ids})")

    # topics by simulated users
    topic_count = DB.query_single("SELECT COUNT(*) FROM topics WHERE user_id IN (#{ids})").first
    DB.exec(
      "DELETE FROM topic_tags WHERE topic_id IN (SELECT id FROM topics WHERE user_id IN (#{ids}))",
    )
    DB.exec(<<~SQL) if ActiveRecord::Base.connection.table_exists?("discourse_solved_solved_topics")
        DELETE FROM discourse_solved_solved_topics
        WHERE topic_id IN (SELECT id FROM topics WHERE user_id IN (#{ids}))
      SQL
    DB.exec("DELETE FROM topics WHERE user_id IN (#{ids})")

    # clean up orphaned topics (all posts removed but topic was created by a real user)
    DB.exec(<<~SQL)
      DELETE FROM topics WHERE id IN (
        SELECT t.id FROM topics t
        LEFT JOIN posts p ON p.topic_id = t.id AND p.deleted_at IS NULL
        WHERE p.id IS NULL AND t.deleted_at IS NULL
      )
    SQL

    # user visits, stats, emails, passwords
    DB.exec("DELETE FROM user_visits WHERE user_id IN (#{ids})")
    DB.exec("DELETE FROM user_stats WHERE user_id IN (#{ids})")
    DB.exec("DELETE FROM user_passwords WHERE user_id IN (#{ids})")
    DB.exec("DELETE FROM user_emails WHERE user_id IN (#{ids})")
    if ActiveRecord::Base.connection.table_exists?("insights_user_geos")
      DB.exec("DELETE FROM insights_user_geos WHERE user_id IN (#{ids})")
    end

    # users themselves
    DB.exec("DELETE FROM users WHERE id IN (#{ids})")

    print "\r  Cleaned batch: #{batch.length} users, #{post_count} posts, #{topic_count} topics, #{like_count} likes"
  end

  # update post like counts for any remaining posts that lost likes
  puts "\nUpdating post like counts..."
  DB.exec(<<~SQL)
    UPDATE posts SET like_count = COALESCE(sub.cnt, 0)
    FROM (
      SELECT post_id, COUNT(*) AS cnt
      FROM post_actions
      WHERE post_action_type_id = #{PostActionType.types[:like]}
        AND deleted_at IS NULL
      GROUP BY post_id
    ) sub
    WHERE posts.id = sub.post_id
  SQL

  # update topic stats for topics that lost replies
  puts "Updating topic statistics..."
  DB.exec(<<~SQL)
    UPDATE topics SET
      posts_count = COALESCE(sub.cnt, 1),
      highest_post_number = COALESCE(sub.max_pn, 1)
    FROM (
      SELECT topic_id, COUNT(*) AS cnt, MAX(post_number) AS max_pn
      FROM posts WHERE deleted_at IS NULL
      GROUP BY topic_id
    ) sub
    WHERE topics.id = sub.topic_id
  SQL

  # clear insights caches
  Discourse.cache.delete(DiscourseInsights::LiveController::CACHE_KEY)
  %w[7d 30d 3m].each { |p| Discourse.cache.delete("insights_#{p}") }

  puts
  puts "=== Done! All simulated activity removed ==="
end
