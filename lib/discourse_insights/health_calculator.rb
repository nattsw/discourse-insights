# frozen_string_literal: true

module ::DiscourseInsights
  class HealthCalculator
    PAGES_PER_SESSION_ESTIMATE = 4

    def initialize(start_date:, end_date:)
      @start_date = start_date.to_date
      @end_date = end_date.to_date
      period_length = (@end_date - @start_date).to_i
      @prior_start = @start_date - period_length
      @prior_end = @start_date - 1.day
    end

    def compute
      {
        health_score: compute_health_score,
        funnel: compute_funnel,
        lifecycle: compute_lifecycle,
        attention_items: compute_attention_items,
        top_content: compute_top_content,
        category_health: compute_category_health,
      }
    end

    private

    # --- health score ---

    def compute_health_score
      scores = {
        activity: compute_activity_score,
        growth: compute_growth_score,
        engagement: compute_engagement_score,
        content: compute_content_score,
        responsiveness: compute_responsiveness_score,
      }

      weights = {
        activity: SiteSetting.insights_activity_weight,
        growth: SiteSetting.insights_growth_weight,
        engagement: SiteSetting.insights_engagement_weight,
        content: SiteSetting.insights_content_weight,
        responsiveness: SiteSetting.insights_responsiveness_weight,
      }

      total_weight = weights.values.sum.to_f
      total_weight = 1.0 if total_weight == 0

      overall =
        scores.sum { |key, score| score * weights[key] } / total_weight
      overall = overall.round

      dimensions =
        scores.transform_values { |score| { score: score, label: score_label(score) } }

      { overall: overall, label: score_label(overall), dimensions: dimensions }
    end

    # DAU/MAU ratio normalized: 20%+ = 100, 5% = 50, <1% = 0
    def compute_activity_score
      period_days = [(@end_date - @start_date).to_i + 1, 1].max

      mau =
        UserVisit.where(visited_at: @start_date..@end_date).distinct.count(:user_id)
      return 0 if mau == 0

      daily_counts =
        UserVisit
          .where(visited_at: @start_date..@end_date)
          .group(:visited_at)
          .distinct
          .count(:user_id)
      dau = daily_counts.values.sum.to_f / period_days

      ratio = (dau / mau) * 100
      normalize_score(ratio, 1, 20)
    end

    # net new members as % of total
    def compute_growth_score
      total_users = User.real.where("created_at <= ?", @end_date.end_of_day).count
      return 0 if total_users == 0

      new_users =
        User.real.where(created_at: @start_date.beginning_of_day..@end_date.end_of_day).count
      growth_pct = (new_users.to_f / total_users) * 100
      normalize_score(growth_pct, 0, 5)
    end

    # % of active members who posted or liked
    def compute_engagement_score
      active_user_ids = current_period_active_user_ids
      return 0 if active_user_ids.empty?

      engaged_count =
        DB.query_single(<<~SQL, start_date: @start_date, end_date: @end_date.end_of_day).first
        SELECT COUNT(DISTINCT user_id) FROM (
          SELECT user_id FROM posts
          WHERE created_at BETWEEN :start_date AND :end_date
            AND user_id IS NOT NULL
            AND deleted_at IS NULL
          UNION
          SELECT acting_user_id AS user_id FROM user_actions
          WHERE action_type = #{UserAction::LIKE}
            AND created_at BETWEEN :start_date AND :end_date
        ) engaged
      SQL

      pct = (engaged_count.to_f / active_user_ids.size) * 100
      normalize_score(pct, 5, 50)
    end

    # % of topics that received at least one reply
    def compute_content_score
      base =
        Topic.where(
          created_at: @start_date.beginning_of_day..@end_date.end_of_day,
          visible: true,
          archetype: Archetype.default,
        )
      total = base.count
      return 0 if total == 0

      replied = base.where("posts_count > 1").count
      pct = (replied.to_f / total) * 100
      normalize_score(pct, 30, 90)
    end

    # inverse of median time to first response
    def compute_responsiveness_score
      hours =
        DB.query_single(<<~SQL, start_date: @start_date, end_date: @end_date.end_of_day).first
        SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (
          ORDER BY EXTRACT(EPOCH FROM (p.created_at - t.created_at)) / 3600
        ) AS median_hours
        FROM topics t
        JOIN posts p ON p.topic_id = t.id AND p.post_number = 2 AND p.deleted_at IS NULL
        WHERE t.created_at BETWEEN :start_date AND :end_date
          AND t.visible = true
          AND t.archetype = 'regular'
          AND t.posts_count > 1
      SQL

      return 50 if hours.nil?
      # <1hr = 100, >24hr = 0
      inverse_normalize_score(hours, 1, 24)
    end

    # --- funnel ---

    def compute_funnel
      anon_pageviews =
        ApplicationRequest
          .where(date: @start_date..@end_date)
          .where(req_type: ApplicationRequest.req_types[:page_view_anon_browser])
          .sum(:count)
      logged_in_pageviews =
        ApplicationRequest
          .where(date: @start_date..@end_date)
          .where(req_type: ApplicationRequest.req_types[:page_view_logged_in_browser])
          .sum(:count)

      visitors =
        (anon_pageviews / PAGES_PER_SESSION_ESTIMATE) +
          UserVisit.where(visited_at: @start_date..@end_date).distinct.count(:user_id)

      logged_in =
        UserVisit.where(visited_at: @start_date..@end_date).distinct.count(:user_id)

      readers =
        UserVisit
          .where(visited_at: @start_date..@end_date)
          .where("posts_read > 0")
          .distinct
          .count(:user_id)

      posters =
        Post
          .where(created_at: @start_date.beginning_of_day..@end_date.end_of_day)
          .where("deleted_at IS NULL")
          .distinct
          .count(:user_id)

      contributors =
        DB.query_single(<<~SQL, start_date: @start_date, end_date: @end_date.end_of_day).first
        SELECT COUNT(*) FROM user_stats
        WHERE first_post_created_at BETWEEN :start_date AND :end_date
      SQL

      login_rate = visitors > 0 ? (logged_in.to_f / visitors * 100).round(1) : 0
      post_rate = logged_in > 0 ? (posters.to_f / logged_in * 100).round(1) : 0

      {
        visitors: visitors,
        logged_in: logged_in,
        readers: readers,
        posters: posters,
        contributors: contributors,
        login_rate: login_rate,
        post_rate: post_rate,
      }
    end

    # --- lifecycle ---

    def compute_lifecycle
      current_ids = current_period_active_user_ids
      prior_ids = prior_period_active_user_ids

      new_user_ids =
        Set.new(
          User
            .real
            .where(created_at: @start_date.beginning_of_day..@end_date.end_of_day)
            .select(:id)
            .map(&:id),
        )

      returning = (current_ids & prior_ids) - new_user_ids
      new_active = current_ids & new_user_ids
      reactivated = current_ids - prior_ids - new_user_ids
      churned = prior_ids - current_ids

      net_growth = (new_active.size + reactivated.size - churned.size)
      returning_pct =
        current_ids.size > 0 ? (returning.size.to_f / current_ids.size * 100).round : 0

      {
        returning: returning.size,
        new: new_active.size,
        reactivated: reactivated.size,
        churned: churned.size,
        net_growth: net_growth,
        returning_pct: returning_pct,
      }
    end

    # --- attention items ---

    def compute_attention_items
      items = []
      threshold = SiteSetting.insights_unanswered_threshold_hours

      unanswered_by_category =
        Topic
          .where(visible: true, archetype: Archetype.default)
          .where("posts_count = 1")
          .where("topics.created_at < ?", threshold.hours.ago)
          .where("topics.created_at >= ?", @start_date.beginning_of_day)
          .joins(:category)
          .group("categories.name")
          .count

      unanswered_by_category.each do |category_name, count|
        items << {
          type: "unanswered_topics",
          count: count,
          category: category_name,
          threshold_hours: threshold,
        }
      end

      active_category_ids =
        Topic
          .where(
            created_at: @start_date.beginning_of_day..@end_date.end_of_day,
            visible: true,
            archetype: Archetype.default,
          )
          .distinct
          .select(:category_id)
          .map(&:category_id)

      Category
        .where(read_restricted: false)
        .where.not(id: active_category_ids)
        .where("topic_count > 0")
        .find_each do |cat|
          items << { type: "inactive_category", category: cat.name }
        end

      current_reply_rate = compute_content_score
      prior_calc =
        self.class.new(start_date: @prior_start, end_date: @prior_end)
      prior_reply_rate = prior_calc.send(:compute_content_score)
      if prior_reply_rate > 0
        change = current_reply_rate - prior_reply_rate
        if change < -5
          items << {
            type: "declining_metric",
            metric: "reply_rate",
            change_pct: change.round(1),
          }
        end
      end

      items
    end

    # --- top content ---

    def compute_top_content
      DB.query(<<~SQL, start_date: @start_date, end_date: @end_date)
        SELECT
          t.id AS topic_id,
          t.title,
          c.name AS category,
          COALESCE(tvs.views, 0) AS views,
          GREATEST(t.posts_count - 1, 0) AS replies,
          t.like_count AS likes
        FROM topics t
        LEFT JOIN categories c ON c.id = t.category_id
        LEFT JOIN (
          SELECT topic_id, SUM(anonymous_views + logged_in_views) AS views
          FROM topic_view_stats
          WHERE viewed_at BETWEEN :start_date AND :end_date
          GROUP BY topic_id
        ) tvs ON tvs.topic_id = t.id
        WHERE t.visible = true
          AND t.archetype = 'regular'
          AND t.deleted_at IS NULL
          AND (t.created_at BETWEEN :start_date AND :end_date OR tvs.views > 0)
        ORDER BY (COALESCE(tvs.views, 0) + GREATEST(t.posts_count - 1, 0) * 10 + t.like_count * 5) DESC
        LIMIT 10
      SQL
        .map { |row| row.to_h }
    end

    # --- category health ---

    def compute_category_health
      rows =
        DB.query(<<~SQL, start_date: @start_date, end_date: @end_date.end_of_day)
        SELECT
          c.id AS category_id,
          c.name,
          c.color,
          COUNT(DISTINCT t.id) AS topic_count,
          COUNT(DISTINCT CASE WHEN t.posts_count > 1 THEN t.id END) AS replied_count,
          PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY CASE WHEN p2.created_at IS NOT NULL
              THEN EXTRACT(EPOCH FROM (p2.created_at - t.created_at)) / 3600
              ELSE NULL END
          ) AS avg_response_hours
        FROM categories c
        LEFT JOIN topics t ON t.category_id = c.id
          AND t.created_at BETWEEN :start_date AND :end_date
          AND t.visible = true
          AND t.archetype = 'regular'
          AND t.deleted_at IS NULL
        LEFT JOIN posts p2 ON p2.topic_id = t.id
          AND p2.post_number = 2
          AND p2.deleted_at IS NULL
        WHERE c.read_restricted = false
        GROUP BY c.id, c.name, c.color
        HAVING COUNT(DISTINCT t.id) > 0
        ORDER BY COUNT(DISTINCT t.id) DESC
      SQL

      rows.map do |row|
        reply_rate = row.topic_count > 0 ? (row.replied_count.to_f / row.topic_count * 100).round : 0
        resp_hours = row.avg_response_hours&.round(1) || 0

        activity_score = normalize_score(row.topic_count, 1, 50)
        reply_score = normalize_score(reply_rate, 30, 90)
        resp_score = row.avg_response_hours ? inverse_normalize_score(row.avg_response_hours, 1, 24) : 50

        health = ((activity_score * 0.3) + (reply_score * 0.4) + (resp_score * 0.3)).round

        {
          category_id: row.category_id,
          name: row.name,
          color: row.color,
          topic_count: row.topic_count,
          reply_rate: reply_rate,
          avg_response_hours: resp_hours,
          health_score: health,
          label: score_label(health),
        }
      end
    end

    # --- helpers ---

    def current_period_active_user_ids
      @current_active ||=
        Set.new(
          UserVisit
            .where(visited_at: @start_date..@end_date)
            .distinct
            .select(:user_id)
            .map(&:user_id),
        )
    end

    def prior_period_active_user_ids
      @prior_active ||=
        Set.new(
          UserVisit
            .where(visited_at: @prior_start..@prior_end)
            .distinct
            .select(:user_id)
            .map(&:user_id),
        )
    end

    def normalize_score(value, min_val, max_val)
      return 0 if value <= min_val
      return 100 if value >= max_val
      ((value - min_val).to_f / (max_val - min_val) * 100).round
    end

    def inverse_normalize_score(value, best_val, worst_val)
      return 100 if value <= best_val
      return 0 if value >= worst_val
      ((worst_val - value).to_f / (worst_val - best_val) * 100).round
    end

    def score_label(score)
      if score >= 80
        "strong"
      elsif score >= 60
        "good"
      elsif score >= 40
        "fair"
      else
        "needs_attention"
      end
    end
  end
end
