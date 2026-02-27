# frozen_string_literal: true

module Jobs
  class ResolveUserGeos < ::Jobs::Scheduled
    every 1.day
    sidekiq_options queue: "low"
    cluster_concurrency 1

    BATCH_SIZE = 1000
    MAX_PER_RUN = 10_000

    def execute(args)
      return unless SiteSetting.insights_enabled

      stale_users.each_slice(BATCH_SIZE) { |batch| resolve_batch(batch) }
    end

    private

    def stale_users
      DB.query(<<~SQL, limit: MAX_PER_RUN)
        SELECT u.id AS user_id, u.ip_address
        FROM users u
        LEFT JOIN insights_user_geos g ON g.user_id = u.id
        WHERE u.id > 0
          AND u.ip_address IS NOT NULL
          AND (g.user_id IS NULL OR g.ip_address IS DISTINCT FROM u.ip_address)
        ORDER BY u.last_seen_at DESC NULLS LAST
        LIMIT :limit
      SQL
    end

    def resolve_batch(users)
      now = Time.zone.now
      rows = []

      users
        .group_by { |u| u.ip_address.to_s }
        .each do |ip, user_rows|
          info = DiscourseIpInfo.get(ip)
          next if info[:country_code].blank?

          user_rows.each do |row|
            rows << {
              user_id: row.user_id,
              country_code: info[:country_code],
              country: info[:country]&.slice(0, 100),
              region: info[:region]&.slice(0, 100),
              city: info[:city]&.slice(0, 100),
              latitude: info[:latitude],
              longitude: info[:longitude],
              ip_address: ip,
              created_at: now,
              updated_at: now,
            }
          end
        end

      InsightsUserGeo.upsert_all(rows, unique_by: :user_id) if rows.present?
    end
  end
end
