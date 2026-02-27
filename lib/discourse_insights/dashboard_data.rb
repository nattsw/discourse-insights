# frozen_string_literal: true

module ::DiscourseInsights
  class DashboardData
    PERIODS = { "7d" => 7, "30d" => 30, "3m" => 90 }.freeze

    def initialize(period: "30d", start_date: nil, end_date: nil)
      if start_date.present? && end_date.present?
        @start_date = Date.parse(start_date.to_s)
        @end_date = Date.parse(end_date.to_s)
        @days = (@end_date - @start_date).to_i + 1
        @period_key = "custom"
      else
        days = PERIODS[period] || 30
        @end_date = Date.today
        @start_date = @end_date - days + 1
        @days = days
        @period_key = period
      end
      @prev_end = @start_date - 1
      @prev_start = @prev_end - @days + 1
    end

    def compute
      result = {
        period: period_info,
        metrics: compute_metrics,
        dau_wau_mau: compute_dau_wau_mau,
        posts_breakdown: compute_posts_breakdown,
        top_topics: compute_top_topics,
        search_terms: compute_search_terms,
        traffic_sources: compute_traffic_sources,
        categories: compute_categories,
      }

      geo = compute_geo_breakdown
      result[:geo_breakdown] = geo if geo.present?

      result
    end

    private

    def period_info
      {
        key: @period_key,
        start_date: @start_date,
        end_date: @end_date,
        comparison_start: @prev_start,
        comparison_end: @prev_end,
      }
    end

    def compute_metrics
      {
        visitors: metric_visitors,
        page_views: metric_page_views,
        new_members: metric_new_members,
        contributors: metric_contributors,
        posts: metric_posts,
        likes: metric_likes,
        solved: metric_solved,
        response_rate: metric_response_rate,
      }
    end

    # --- individual metrics ---

    def metric_visitors
      current_daily =
        UserVisit
          .where(visited_at: @start_date..@end_date)
          .group(:visited_at)
          .distinct
          .count(:user_id)
      prev_daily =
        UserVisit
          .where(visited_at: @prev_start..@prev_end)
          .group(:visited_at)
          .distinct
          .count(:user_id)

      current_total = current_daily.values.sum
      prev_total = prev_daily.values.sum

      daily = daily_series(current_daily, prev_daily)
      peak = daily.max_by { |d| d[:value] }

      build_metric(current_total, prev_total, daily:, peak:)
    end

    def metric_page_views
      req_types = [
        ApplicationRequest.req_types[:page_view_anon_browser],
        ApplicationRequest.req_types[:page_view_logged_in_browser],
      ]

      current_daily =
        ApplicationRequest
          .where(date: @start_date..@end_date, req_type: req_types)
          .group(:date)
          .sum(:count)
      prev_daily =
        ApplicationRequest
          .where(date: @prev_start..@prev_end, req_type: req_types)
          .group(:date)
          .sum(:count)

      current_total = current_daily.values.sum
      prev_total = prev_daily.values.sum
      avg_per_day = @days > 0 ? (current_total.to_f / @days).round : 0

      build_metric(
        current_total,
        prev_total,
        daily: daily_series(current_daily, prev_daily),
        avg_per_day:,
      )
    end

    def metric_new_members
      current_daily =
        User
          .real
          .where(created_at: @start_date.beginning_of_day..@end_date.end_of_day)
          .group("created_at::date")
          .count
      prev_daily =
        User
          .real
          .where(created_at: @prev_start.beginning_of_day..@prev_end.end_of_day)
          .group("created_at::date")
          .count

      current_total = current_daily.values.sum
      prev_total = prev_daily.values.sum

      build_metric(current_total, prev_total, daily: daily_series(current_daily, prev_daily))
    end

    def metric_contributors
      current =
        Post
          .joins(:topic)
          .where(created_at: @start_date.beginning_of_day..@end_date.end_of_day, deleted_at: nil)
          .where(topics: { archetype: Archetype.default })
          .distinct
          .count(:user_id)
      previous =
        Post
          .joins(:topic)
          .where(created_at: @prev_start.beginning_of_day..@prev_end.end_of_day, deleted_at: nil)
          .where(topics: { archetype: Archetype.default })
          .distinct
          .count(:user_id)

      build_metric(current, previous)
    end

    def metric_posts
      current_daily =
        Post
          .joins(:topic)
          .where(created_at: @start_date.beginning_of_day..@end_date.end_of_day, deleted_at: nil)
          .where(topics: { archetype: Archetype.default })
          .group("posts.created_at::date")
          .count
      prev_daily =
        Post
          .joins(:topic)
          .where(created_at: @prev_start.beginning_of_day..@prev_end.end_of_day, deleted_at: nil)
          .where(topics: { archetype: Archetype.default })
          .group("posts.created_at::date")
          .count

      current_total = current_daily.values.sum
      prev_total = prev_daily.values.sum

      build_metric(current_total, prev_total, daily: daily_series(current_daily, prev_daily))
    end

    def metric_likes
      current_daily =
        UserAction
          .where(
            action_type: UserAction::LIKE,
            created_at: @start_date.beginning_of_day..@end_date.end_of_day,
          )
          .group("created_at::date")
          .count
      prev_daily =
        UserAction
          .where(
            action_type: UserAction::LIKE,
            created_at: @prev_start.beginning_of_day..@prev_end.end_of_day,
          )
          .group("created_at::date")
          .count

      current_total = current_daily.values.sum
      prev_total = prev_daily.values.sum

      posts_in_period =
        Post
          .joins(:topic)
          .where(created_at: @start_date.beginning_of_day..@end_date.end_of_day, deleted_at: nil)
          .where(topics: { archetype: Archetype.default })
          .count
      like_ratio = posts_in_period > 0 ? (current_total.to_f / posts_in_period).round(1) : 0

      build_metric(
        current_total,
        prev_total,
        daily: daily_series(current_daily, prev_daily),
        like_to_post_ratio: like_ratio,
      )
    end

    def metric_solved
      return build_metric(0, 0, available: false) unless solved_plugin_available?

      current = solved_count_between(@start_date, @end_date)
      previous = solved_count_between(@prev_start, @prev_end)

      total_support =
        Topic.where(
          created_at: @start_date.beginning_of_day..@end_date.end_of_day,
          visible: true,
          archetype: Archetype.default,
        ).count
      solve_rate = total_support > 0 ? (current.to_f / total_support * 100).round : 0

      build_metric(current, previous, available: true, solve_rate:)
    end

    def metric_response_rate
      current_rate = response_rate_for(@start_date, @end_date)
      previous_rate = response_rate_for(@prev_start, @prev_end)
      diff = current_rate - previous_rate

      avg_hours = avg_first_response_hours(@start_date, @end_date)
      prev_avg_hours = avg_first_response_hours(@prev_start, @prev_end)

      threshold = SiteSetting.insights_unanswered_threshold_hours
      unanswered =
        Topic
          .where(visible: true, archetype: Archetype.default, posts_count: 1)
          .where(
            "topics.created_at BETWEEN ? AND ?",
            @start_date.beginning_of_day,
            @end_date.end_of_day,
          )
          .where("topics.created_at < ?", threshold.hours.ago)
          .count

      {
        current: current_rate,
        previous: previous_rate,
        trend_pct: diff.round(1),
        is_percentage: true,
        avg_first_response_hours: avg_hours,
        prev_avg_first_response_hours: prev_avg_hours,
        unanswered_count: unanswered,
      }
    end

    # --- aggregates ---

    def compute_dau_wau_mau
      rows = UserVisit.count_by_active_users(@start_date, @end_date)
      return { dau: 0, wau: 0, mau: 0, dau_mau_ratio: 0 } if rows.empty?

      latest = rows.last
      dau = latest["dau"]
      mau = latest["mau"]
      wau =
        UserVisit
          .where(visited_at: ([@end_date - 6, @start_date].max)..@end_date)
          .distinct
          .count(:user_id)

      ratio = mau > 0 ? (dau.to_f / mau * 100).round(1) : 0
      { dau:, wau:, mau:, dau_mau_ratio: ratio }
    end

    def compute_posts_breakdown
      range = @start_date.beginning_of_day..@end_date.end_of_day
      new_topics = Topic.where(created_at: range, archetype: Archetype.default, visible: true).count
      total_posts =
        Post
          .joins(:topic)
          .where(created_at: range, deleted_at: nil)
          .where(topics: { archetype: Archetype.default })
          .count
      replies = [total_posts - new_topics, 0].max
      { topics: new_topics, replies: }
    end

    def compute_top_topics
      DB.query(<<~SQL, start_date: @start_date, end_date: @end_date).map(&:to_h)
        SELECT
          t.id AS topic_id,
          t.title,
          COALESCE(tvs.views, 0) AS views,
          GREATEST(t.posts_count - 1, 0) AS replies
        FROM topics t
        JOIN categories c ON c.id = t.category_id AND c.read_restricted = false
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
        ORDER BY COALESCE(tvs.views, 0) DESC
        LIMIT 10
      SQL
    end

    def compute_search_terms
      SearchLog
        .trending_from(@start_date, end_date: @end_date, limit: 10)
        .map do |row|
          ctr = row.searches > 0 ? (row.click_through.to_f / row.searches * 100).round : 0
          { term: row.term, count: row.searches, ctr:, content_gap: ctr < 20 }
        end
    end

    def compute_traffic_sources
      IncomingLink
        .where(created_at: @start_date.beginning_of_day..@end_date.end_of_day)
        .joins(incoming_referer: :incoming_domain)
        .group("incoming_domains.name")
        .order("count_all DESC")
        .limit(10)
        .count
        .map { |domain, count| { domain:, clicks: count } }
    end

    def compute_categories
      current_data = category_stats_for(@start_date, @end_date)
      prev_data = category_stats_for(@prev_start, @prev_end)

      current_data.map do |cat|
        prev = prev_data.find { |p| p[:category_id] == cat[:category_id] }
        prev_activity = prev ? (prev[:new_topics] + prev[:replies]) : 0
        current_activity = cat[:new_topics] + cat[:replies]

        trend_pct =
          if prev_activity > 0
            ((current_activity - prev_activity).to_f / prev_activity * 100).round
          else
            0
          end

        cat.merge(trend_pct:)
      end
    end

    def compute_geo_breakdown
      return [] unless ActiveRecord::Base.connection.table_exists?(:insights_user_geos)

      rows = DB.query(<<~SQL, start_date: @start_date, end_date: @end_date)
          SELECT
            g.country_code,
            g.country,
            COUNT(DISTINCT uv.user_id) AS count,
            AVG(g.latitude) AS latitude,
            AVG(g.longitude) AS longitude
          FROM user_visits uv
          JOIN insights_user_geos g ON g.user_id = uv.user_id
          WHERE uv.visited_at BETWEEN :start_date AND :end_date
            AND g.country_code IS NOT NULL
          GROUP BY g.country_code, g.country
          ORDER BY count DESC
          LIMIT 50
        SQL

      total = rows.sum(&:count)
      return [] if total == 0

      rows.map do |row|
        {
          country_code: row.country_code,
          country: row.country,
          count: row.count,
          pct: (row.count.to_f / total * 100).round(1),
          latitude: row.latitude&.round(2),
          longitude: row.longitude&.round(2),
        }
      end
    end

    # --- helpers ---

    def build_metric(current, previous, **extra)
      trend =
        if previous > 0
          ((current - previous).to_f / previous * 100).round
        else
          current > 0 ? 100 : 0
        end

      { current:, previous:, trend_pct: trend, **extra }
    end

    def daily_series(current_grouped, prev_grouped = {})
      (@start_date..@end_date).map do |date|
        prev_date = date - @days
        {
          date: date.to_s,
          value: current_grouped[date] || 0,
          previous: prev_grouped[prev_date] || 0,
        }
      end
    end

    def solved_plugin_available?
      defined?(::DiscourseSolved) &&
        ActiveRecord::Base.connection.table_exists?("discourse_solved_solved_topics")
    end

    def solved_count_between(start_date, end_date)
      DB.query_single(
        <<~SQL,
        SELECT COUNT(*)
        FROM discourse_solved_solved_topics st
        JOIN topics t ON t.id = st.topic_id
        WHERE st.created_at BETWEEN :start_date AND :end_date
          AND t.deleted_at IS NULL AND t.visible = true
      SQL
        start_date: start_date.beginning_of_day,
        end_date: end_date.end_of_day,
      ).first || 0
    end

    def response_rate_for(start_date, end_date)
      total =
        Topic.where(
          created_at: start_date.beginning_of_day..end_date.end_of_day,
          visible: true,
          archetype: Archetype.default,
        ).count
      return 0 if total == 0

      replied =
        Topic
          .where(
            created_at: start_date.beginning_of_day..end_date.end_of_day,
            visible: true,
            archetype: Archetype.default,
          )
          .where("posts_count > 1")
          .count

      (replied.to_f / total * 100).round
    end

    def avg_first_response_hours(start_date, end_date)
      result =
        DB.query_single(
          <<~SQL,
          SELECT AVG(EXTRACT(EPOCH FROM (p.created_at - t.created_at)) / 3600)
          FROM topics t
          JOIN posts p ON p.topic_id = t.id AND p.post_number = 2 AND p.deleted_at IS NULL
          WHERE t.created_at BETWEEN :start_date AND :end_date
            AND t.visible = true AND t.archetype = 'regular' AND t.posts_count > 1
        SQL
          start_date: start_date.beginning_of_day,
          end_date: end_date.end_of_day,
        ).first

      result&.round(1) || 0
    end

    def category_stats_for(start_date, end_date)
      DB.query(<<~SQL, start_date: start_date.beginning_of_day, end_date: end_date.end_of_day).map(
          SELECT
            c.id AS category_id,
            c.name,
            c.color,
            COALESCE(tvs.page_views, 0) AS page_views,
            COUNT(DISTINCT t.id) FILTER (WHERE t.id IS NOT NULL) AS new_topics,
            COALESCE(SUM(GREATEST(t.posts_count - 1, 0)) FILTER (WHERE t.id IS NOT NULL), 0)::int AS replies
          FROM categories c
          LEFT JOIN topics t ON t.category_id = c.id
            AND t.created_at BETWEEN :start_date AND :end_date
            AND t.visible = true
            AND t.archetype = 'regular'
            AND t.deleted_at IS NULL
          LEFT JOIN (
            SELECT t2.category_id, SUM(tvs2.anonymous_views + tvs2.logged_in_views) AS page_views
            FROM topic_view_stats tvs2
            JOIN topics t2 ON t2.id = tvs2.topic_id
            WHERE tvs2.viewed_at BETWEEN :start_date AND :end_date
            GROUP BY t2.category_id
          ) tvs ON tvs.category_id = c.id
          WHERE c.read_restricted = false
          GROUP BY c.id, c.name, c.color, tvs.page_views
          HAVING COUNT(DISTINCT t.id) FILTER (WHERE t.id IS NOT NULL) > 0
            OR COALESCE(tvs.page_views, 0) > 0
          ORDER BY COALESCE(tvs.page_views, 0) DESC
        SQL
        &:to_h
      )
    end
  end
end
