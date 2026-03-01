# frozen_string_literal: true

# name: discourse-insights
# about: A plugin to help monitor and improve the health of a Discourse community.
# meta_topic_id: TODO
# version: 0.0.1
# authors: Discourse
# url: https://github.com/nattsw/discourse-insights
# required_version: 2.7.0

enabled_site_setting :insights_enabled

register_asset "stylesheets/insights.scss"

module ::DiscourseInsights
  PLUGIN_NAME = "discourse-insights"
  AI_PERSONA_NAME = "Insights Advisor"
  REPORT_IDS_CUSTOM_FIELD = "insights_report_ids"

  SEEDED_QUERIES = [
    # default top 4
    { name: "Active Users", description: "Unique users who visited.", sql: <<~SQL },
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT DATE_TRUNC('week', visited_at)::date AS week, COUNT(DISTINCT user_id) AS active_users
        FROM user_visits
        WHERE visited_at BETWEEN :start_date AND :end_date
        GROUP BY week ORDER BY week
      SQL
    { name: "Topics by Category", description: "New topics per category.", sql: <<~SQL },
        -- [params]
        -- date :start_date = #{30.days.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT c.name AS category, COUNT(*) AS topics
        FROM topics t
        JOIN categories c ON c.id = t.category_id
        WHERE t.created_at BETWEEN :start_date AND (:end_date::date + 1)
          AND t.deleted_at IS NULL
          AND t.visible = true
          AND t.archetype = 'regular'
        GROUP BY c.name
        ORDER BY topics DESC
        LIMIT 15
      SQL
    {
      name: "Category Deep Dive",
      description:
        "New topics, replies, and likes for a single category. Use the category picker to switch between categories.",
      sql: <<~SQL,
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        -- category_id :category_id = 1
        SELECT
          DATE_TRUNC('week', t.created_at)::date AS week,
          COUNT(DISTINCT t.id) AS new_topics,
          COUNT(DISTINCT p.id) FILTER (WHERE p.post_number > 1) AS replies,
          COALESCE(SUM(p.like_count) FILTER (WHERE p.post_number > 1), 0) AS likes
        FROM topics t
        LEFT JOIN posts p ON p.topic_id = t.id
          AND p.deleted_at IS NULL
          AND p.post_type = 1
          AND p.created_at BETWEEN :start_date AND (:end_date::date + 1)
        WHERE t.category_id = :category_id
          AND t.created_at BETWEEN :start_date AND (:end_date::date + 1)
          AND t.deleted_at IS NULL
          AND t.visible = true
          AND t.archetype = 'regular'
        GROUP BY week
        ORDER BY week
      SQL
    },
    {
      name: "Member Lifecycle",
      description:
        "Returning, new, reactivated, and churned members. Shows community retention health.",
      sql: <<~SQL,
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT
          classified.week,
          COUNT(*) FILTER (WHERE classified.in_cur AND classified.in_prev AND NOT classified.is_new) AS returning,
          COUNT(*) FILTER (WHERE classified.in_cur AND classified.is_new) AS new,
          COUNT(*) FILTER (WHERE classified.in_cur AND NOT classified.in_prev AND NOT classified.is_new) AS reactivated,
          COUNT(*) FILTER (WHERE NOT classified.in_cur AND classified.in_prev) AS churned
        FROM (
          SELECT
            pairs.week_start AS week,
            pairs.user_id,
            bool_or(pairs.in_cur) AS in_cur,
            bool_or(pairs.in_prev) AS in_prev,
            bool_or(u.created_at >= pairs.week_start AND u.created_at < pairs.week_start + 7) AS is_new
          FROM (
            SELECT DATE_TRUNC('week', visited_at)::date AS week_start, user_id,
                   true AS in_cur, false AS in_prev
            FROM user_visits
            WHERE visited_at BETWEEN :start_date::date AND :end_date
            GROUP BY 1, 2
            UNION ALL
            SELECT (DATE_TRUNC('week', visited_at) + '7 days'::interval)::date AS week_start, user_id,
                   false AS in_cur, true AS in_prev
            FROM user_visits
            WHERE visited_at BETWEEN (:start_date::date - 7) AND :end_date
            GROUP BY 1, 2
          ) pairs
          LEFT JOIN users u ON u.id = pairs.user_id
          GROUP BY pairs.week_start, pairs.user_id
        ) classified
        WHERE classified.week BETWEEN DATE_TRUNC('week', :start_date::date)::date
                                  AND DATE_TRUNC('week', :end_date::date)::date
        GROUP BY classified.week
        ORDER BY classified.week
      SQL
    },
    # remaining reports
    { name: "New Signups", description: "New user registrations.", sql: <<~SQL },
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT DATE_TRUNC('week', created_at)::date AS week, COUNT(*) AS signups
        FROM users
        WHERE created_at BETWEEN :start_date AND (:end_date::date + 1)
          AND id > 0
        GROUP BY week ORDER BY week
      SQL
    {
      name: "Pageviews by Type",
      description:
        "Daily browser pageviews broken down by logged-in, anonymous, crawler, and other traffic.",
      sql: <<~SQL,
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT
          ar.date::date AS day,
          SUM(CASE WHEN ar.req_type = 15 THEN count ELSE 0 END) AS "Logged In",
          SUM(CASE WHEN ar.req_type = 13 THEN count ELSE 0 END) AS "Anonymous",
          SUM(CASE WHEN ar.req_type = 6 THEN count ELSE 0 END) AS "Crawlers",
          SUM(
            CASE WHEN ar.req_type IN (7, 8) THEN count
                 WHEN ar.req_type IN (13, 15) THEN -count
                 ELSE 0
            END
          ) AS "Other"
        FROM application_requests ar
        WHERE ar.date::date BETWEEN :start_date AND :end_date
        GROUP BY ar.date
        ORDER BY ar.date
      SQL
    },
    { name: "Posts Created", description: "Posts created.", sql: <<~SQL },
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT DATE_TRUNC('week', p.created_at)::date AS week, COUNT(*) AS posts
        FROM posts p
        JOIN topics t ON t.id = p.topic_id
        WHERE p.created_at BETWEEN :start_date AND (:end_date::date + 1)
          AND p.deleted_at IS NULL
          AND t.archetype = 'regular'
        GROUP BY week ORDER BY week
      SQL
    { name: "Likes Given", description: "Likes given.", sql: <<~SQL },
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT DATE_TRUNC('week', created_at)::date AS week, COUNT(*) AS likes
        FROM user_actions
        WHERE created_at BETWEEN :start_date AND (:end_date::date + 1)
          AND action_type = 1
        GROUP BY week ORDER BY week
      SQL
    {
      name: "Solved Topics",
      description:
        "Topics with an accepted solution. Shows whether support deflection is working. Requires the Solved plugin.",
      sql: <<~SQL,
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT DATE_TRUNC('week', st.created_at)::date AS week, COUNT(*) AS solved_topics
        FROM discourse_solved_solved_topics st
        WHERE st.created_at BETWEEN :start_date AND (:end_date::date + 1)
        GROUP BY week ORDER BY week
      SQL
    },
    {
      name: "Unanswered Topics",
      description: "Topics that received no replies. Shows the support gap.",
      sql: <<~SQL,
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT DATE_TRUNC('week', t.created_at)::date AS week, COUNT(*) AS unanswered
        FROM topics t
        WHERE t.created_at BETWEEN :start_date AND (:end_date::date + 1)
          AND t.posts_count = 1
          AND t.deleted_at IS NULL
          AND t.visible = true
          AND t.archetype = 'regular'
        GROUP BY week ORDER BY week
      SQL
    },
    {
      name: "Avg First Response Time",
      description: "Average hours until a topic receives its first reply. Lower is better.",
      sql: <<~SQL,
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT week, ROUND(AVG(hours_to_response)::numeric, 1) AS avg_hours
        FROM (
          SELECT DATE_TRUNC('week', t.created_at)::date AS week,
                 EXTRACT(EPOCH FROM MIN(p.created_at) - t.created_at) / 3600.0 AS hours_to_response
          FROM topics t
          JOIN posts p ON p.topic_id = t.id
          WHERE t.created_at BETWEEN :start_date AND (:end_date::date + 1)
            AND t.archetype = 'regular'
            AND t.deleted_at IS NULL
            AND p.deleted_at IS NULL
            AND p.post_number > 1
            AND p.user_id != t.user_id
            AND p.post_type = 1
          GROUP BY t.id, week
        ) per_topic
        GROUP BY week ORDER BY week
      SQL
    },
    {
      name: "Engaged Users",
      description:
        "Unique users who posted, replied, or liked. Measures engagement depth beyond visits.",
      sql: <<~SQL,
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT DATE_TRUNC('week', created_at)::date AS week, COUNT(DISTINCT user_id) AS engaged_users
        FROM user_actions
        WHERE created_at BETWEEN :start_date AND (:end_date::date + 1)
          AND action_type IN (1, 4, 5)
        GROUP BY week ORDER BY week
      SQL
    },
    {
      name: "Trust Level Promotions",
      description: "Users promoted to a higher trust level. Shows community maturation over time.",
      sql: <<~SQL,
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT DATE_TRUNC('week', created_at)::date AS week, COUNT(*) AS promotions
        FROM user_histories
        WHERE created_at BETWEEN :start_date AND (:end_date::date + 1)
          AND action IN (2, 15)
          AND new_value::int > previous_value::int
        GROUP BY week ORDER BY week
      SQL
    },
    {
      name: "Reply Rate by Category",
      description:
        "Percentage of topics that received at least one reply, broken down by category. Shows where the community is helping itself and where support gaps exist.",
      sql: <<~SQL,
        -- [params]
        -- date :start_date = #{30.days.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT
          c.name AS category,
          ROUND(COUNT(*) FILTER (WHERE t.posts_count > 1) * 100.0 / GREATEST(COUNT(*), 1)) AS reply_rate_pct
        FROM topics t
        JOIN categories c ON c.id = t.category_id
        WHERE t.created_at BETWEEN :start_date AND (:end_date::date + 1)
          AND t.deleted_at IS NULL
          AND t.visible = true
          AND t.archetype = 'regular'
        GROUP BY c.name
        HAVING COUNT(*) >= 3
        ORDER BY reply_rate_pct ASC
      SQL
    },
    {
      name: "Response Time by Category",
      description:
        "Average and median hours to first reply per category. Lower is better. Helps identify which areas need faster responses.",
      sql: <<~SQL,
        -- [params]
        -- date :start_date = #{30.days.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT
          c.name AS category,
          ROUND(AVG(hours)::numeric, 1) AS avg_hours,
          ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY hours)::numeric, 1) AS median_hours
        FROM (
          SELECT t.category_id,
                 EXTRACT(EPOCH FROM MIN(p.created_at) - t.created_at) / 3600.0 AS hours
          FROM topics t
          JOIN posts p ON p.topic_id = t.id
          WHERE t.created_at BETWEEN :start_date AND (:end_date::date + 1)
            AND p.created_at BETWEEN :start_date AND (:end_date::date + 30)
            AND t.archetype = 'regular'
            AND t.deleted_at IS NULL
            AND p.deleted_at IS NULL
            AND p.post_number > 1
            AND p.user_id != t.user_id
            AND p.post_type = 1
          GROUP BY t.id, t.category_id
        ) per_topic
        JOIN categories c ON c.id = per_topic.category_id
        GROUP BY c.name
        ORDER BY median_hours DESC
      SQL
    },
    {
      name: "Unanswered Topics by Category",
      description:
        "Topics with no replies, broken down by category. Highlights where the support gap is biggest.",
      sql: <<~SQL,
        -- [params]
        -- date :start_date = #{30.days.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT
          c.name AS category,
          COUNT(*) AS unanswered_topics
        FROM topics t
        JOIN categories c ON c.id = t.category_id
        WHERE t.created_at BETWEEN :start_date AND (:end_date::date + 1)
          AND t.posts_count = 1
          AND t.deleted_at IS NULL
          AND t.visible = true
          AND t.archetype = 'regular'
        GROUP BY c.name
        ORDER BY unanswered_topics DESC
      SQL
    },
    {
      name: "Moderator vs Community Posts",
      description:
        "Posts by staff (admins + moderators) vs. community members. A healthy community has a low staff ratio — aim for staff posts under 20% of total.",
      sql: <<~SQL,
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT
          DATE_TRUNC('week', p.created_at)::date AS week,
          COUNT(*) FILTER (WHERE u.admin OR u.moderator) AS staff_posts,
          COUNT(*) FILTER (WHERE NOT u.admin AND NOT u.moderator) AS community_posts
        FROM posts p
        JOIN users u ON u.id = p.user_id
        WHERE p.created_at BETWEEN :start_date AND (:end_date::date + 1)
          AND p.deleted_at IS NULL
          AND p.post_type = 1
          AND u.id > 0
        GROUP BY week
        ORDER BY week
      SQL
    },
  ].freeze
end

require_relative "lib/discourse_insights/engine"

after_initialize do
  register_user_custom_field_type(DiscourseInsights::REPORT_IDS_CUSTOM_FIELD, :json)

  if defined?(DiscourseDataExplorer)
    seeded_ids =
      DiscourseInsights::SEEDED_QUERIES.map do |q|
        query = DiscourseDataExplorer::Query.find_or_initialize_by(name: q[:name])
        query.description = q[:description]
        query.sql = q[:sql]
        query.user_id ||= Discourse::SYSTEM_USER_ID
        query.save!
        query.id
      end
    old_seeded_ids = PluginStore.get(DiscourseInsights::PLUGIN_NAME, "seeded_query_ids") || []
    orphaned_ids = old_seeded_ids - seeded_ids
    DiscourseDataExplorer::Query.where(id: orphaned_ids).destroy_all if orphaned_ids.present?

    PluginStore.set(DiscourseInsights::PLUGIN_NAME, "seeded_query_ids", seeded_ids)

    sync_query_groups =
      lambda do |query_ids|
        group_ids = SiteSetting.insights_allowed_groups_map
        query_ids.each do |query_id|
          group_ids.each do |group_id|
            DiscourseDataExplorer::QueryGroup.find_or_create_by(
              query_id: query_id,
              group_id: group_id,
            )
          end
        end
      end

    sync_query_groups.call(seeded_ids)

    on(:site_setting_changed) do |name, _old, _new|
      if name == :insights_allowed_groups
        ids = PluginStore.get(DiscourseInsights::PLUGIN_NAME, "seeded_query_ids") || []
        sync_query_groups.call(ids) if ids.present?
      end
    end
  end

  if defined?(DiscourseAi)
    persona = AiPersona.find_or_initialize_by(name: DiscourseInsights::AI_PERSONA_NAME)
    persona.description = I18n.t("discourse_insights.ai_persona.description")
    persona.system_prompt = <<~PROMPT
      You are an insights advisor for a Discourse community forum. You help community managers understand their community's health, spot trends, and communicate value to stakeholders.

      You may receive community metrics as structured JSON, partial data, or a plain-language question. Work with whatever is provided — synthesize the numbers into clear, actionable insights rather than restating them. If data is missing, focus on what's available and say so briefly rather than guessing.

      ## What community managers care about

      Enterprise community managers need to answer three questions:
      1. **Is support deflection working?** Are community members helping each other? Are questions getting answered? Is response time improving?
      2. **Is engagement deepening?** Are visitors becoming members? Are members posting and contributing? Is activity growing or concentrated in a small core?
      3. **Can I demonstrate ROI to stakeholders?** What's the headline? What's improving? What needs investment?

      ## How to write insights

      - The user can already see every number on the dashboard. NEVER restate metrics. Your job is to explain what the numbers mean and what to do about them.
      - Lead with the insight, not the number. Say "your community is becoming self-sustaining — members are answering questions before staff need to" not "response rate: 82% (up 5%)."
      - Connect metrics to each other. A visitor increase paired with flat signups means your funnel is leaking. A post increase with fewer contributors means a small group is doing all the work. These cross-metric stories are what the user can't see on their own.
      - Compare to the previous period. Trends matter more than absolutes.
      - Be specific about what's good and what needs attention. Don't hedge.
      - When something is declining, suggest a concrete action.
      - Keep it short. 2-3 sentences for a summary, 3-4 for a question answer.
      - Use plain language a non-technical community manager would understand.
      - Never fabricate or hallucinate data. Only reference metrics provided to you.

      ## Data format

      When provided, the JSON may include some or all of:
      - `period`: date range and comparison dates
      - `metrics`: visitors, page_views, new_members, contributors, posts, likes, solved, response_rate — each with `current`, `previous`, `trend_pct`, and `daily` sparkline values
      - `categories`: per-category page_views, new_topics, replies, trend_pct
      - `top_topics`: highest-engagement topics with views, replies, likes
      - `search_terms`: what users search for, with click-through rates and `content_gap` flags
      - `traffic_sources`: top referral domains with click counts
      - `dau_wau_mau`: daily/weekly/monthly active users and DAU/MAU ratio
      - `posts_breakdown`: new topics vs replies

      Not all fields will always be present. Base your response only on what's provided.

      ## Output types

      **summary**: 2-3 sentence narrative. Identify the single most important change this period and explain WHY it matters for this community. Name one opportunity or one risk. Do not list metrics — tell the story the metrics reveal. Avoid generic suggestions.

      **categories**: Identify categories with declining engagement. Suggest specific actions (pin a discussion, create seed content, engage regulars).

      **content**: Look at search terms with content gaps and underserved categories. Recommend specific topics to create.

      **deflection**: Analyze solved count, response rate, average response time, unanswered topics. Frame as "how well is the community helping itself?"

      **stakeholder**: Executive-style summary for a VP or director. Lead with the headline metric, 2-3 supporting points, one recommendation. Should be copy-pasteable into an email or slide.
    PROMPT
    persona.allowed_group_ids ||= [Group::AUTO_GROUPS[:staff]]
    persona.enabled = false if persona.new_record?
    persona.tools = [%w[Search], %w[Read]]
    persona.created_by_id ||= Discourse::SYSTEM_USER_ID
    persona.save!
  end
end
