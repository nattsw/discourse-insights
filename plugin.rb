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

  SEEDED_QUERIES = [
    {
      name: "Weekly Active Users",
      description: "Unique users who visited each week.",
      sql: <<~SQL,
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT DATE_TRUNC('week', visited_at)::date AS week, COUNT(DISTINCT user_id) AS active_users
        FROM user_visits
        WHERE visited_at BETWEEN :start_date AND :end_date
        GROUP BY week ORDER BY week
      SQL
    },
    { name: "New Signups Per Week", description: "New user registrations per week.", sql: <<~SQL },
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT DATE_TRUNC('week', created_at)::date AS week, COUNT(*) AS signups
        FROM users
        WHERE created_at BETWEEN :start_date AND (:end_date::date + 1)
          AND id > 0
        GROUP BY week ORDER BY week
      SQL
    { name: "Posts Per Week", description: "Posts created per week.", sql: <<~SQL },
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
    { name: "Likes Per Week", description: "Likes given per week.", sql: <<~SQL },
        -- [params]
        -- date :start_date = #{12.weeks.ago.to_date}
        -- date :end_date = #{Date.today}
        SELECT DATE_TRUNC('week', created_at)::date AS week, COUNT(*) AS likes
        FROM user_actions
        WHERE created_at BETWEEN :start_date AND (:end_date::date + 1)
          AND action_type = 1
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
      name: "Solved Topics Per Week",
      description:
        "Topics with an accepted solution per week. Shows whether support deflection is working. Requires the Solved plugin.",
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
      name: "Unanswered Topics Per Week",
      description:
        "Topics that received no replies, grouped by the week they were created. Shows the support gap.",
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
      name: "Avg First Response Time Per Week",
      description:
        "Average hours until a topic receives its first reply, per week. Lower is better.",
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
      name: "Engaged Users Per Week",
      description:
        "Unique users who posted, replied, or liked each week. Measures engagement depth beyond visits.",
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
      name: "Trust Level Promotions Per Week",
      description:
        "Users promoted to a higher trust level each week. Shows community maturation over time.",
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
  ].freeze
end

require_relative "lib/discourse_insights/engine"

after_initialize do
  if defined?(DiscourseDataExplorer)
    seeded_ids =
      DiscourseInsights::SEEDED_QUERIES.map do |q|
        query = DiscourseDataExplorer::Query.find_or_initialize_by(name: q[:name])
        query.description = q[:description]
        query.sql = q[:sql]
        query.save!
        query.id
      end
    PluginStore.set(DiscourseInsights::PLUGIN_NAME, "seeded_query_ids", seeded_ids)
  end

  if defined?(DiscourseAi)
    persona = AiPersona.find_or_initialize_by(name: "Insights Advisor")
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

      - Lead with the insight, not the number. Say "engagement is deepening — 15% more members posted this period" not "posts: 1,234 (up 15%)."
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

      **summary**: 2-3 sentence narrative. Lead with the most important trend. Mention one bright spot and one area to watch.

      **categories**: Identify categories with declining engagement. Suggest specific actions (pin a discussion, create seed content, engage regulars).

      **content**: Look at search terms with content gaps and underserved categories. Recommend specific topics to create.

      **deflection**: Analyze solved count, response rate, average response time, unanswered topics. Frame as "how well is the community helping itself?"

      **stakeholder**: Executive-style summary for a VP or director. Lead with the headline metric, 2-3 supporting points, one recommendation. Should be copy-pasteable into an email or slide.
    PROMPT
    persona.allowed_group_ids ||= [Group::AUTO_GROUPS[:staff]]
    persona.enabled = false if persona.new_record?
    persona.tools = [%w[Search], %w[Read]]
    persona.save!
  end
end
