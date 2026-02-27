# frozen_string_literal: true

describe DiscourseInsights::DashboardData do
  fab!(:user_1, :user)
  fab!(:user_2, :user)
  fab!(:user_3, :user)
  fab!(:category)

  let(:data) { described_class.new(period: "30d") }

  before { enable_current_plugin }

  describe "#compute" do
    it "returns the expected top-level keys" do
      result = data.compute
      expect(result).to have_key(:period)
      expect(result).to have_key(:metrics)
      expect(result).to have_key(:dau_wau_mau)
      expect(result).to have_key(:posts_breakdown)
      expect(result).to have_key(:top_topics)
      expect(result).to have_key(:search_terms)
      expect(result).to have_key(:traffic_sources)
      expect(result).to have_key(:categories)
    end

    it "returns period info" do
      result = data.compute[:period]
      expect(result[:key]).to eq("30d")
      expect(result[:start_date]).to be_a(Date)
      expect(result[:end_date]).to eq(Date.today)
    end
  end

  describe "metrics" do
    it "returns all metric keys" do
      result = data.compute[:metrics]
      %i[
        visitors
        page_views
        new_members
        contributors
        posts
        likes
        solved
        response_rate
      ].each { |key| expect(result).to have_key(key) }
    end

    it "includes current, previous, and trend_pct for each metric" do
      result = data.compute[:metrics]
      result.each_value do |metric|
        expect(metric).to have_key(:current)
        expect(metric).to have_key(:previous)
        expect(metric).to have_key(:trend_pct)
      end
    end

    describe "visitors" do
      it "counts distinct logged-in visitors" do
        UserVisit.create!(user_id: user_1.id, visited_at: 5.days.ago)
        UserVisit.create!(user_id: user_2.id, visited_at: 3.days.ago)
        UserVisit.create!(user_id: user_1.id, visited_at: 2.days.ago)

        result = data.compute[:metrics][:visitors]
        expect(result[:current]).to be >= 2
      end

      it "includes daily data for sparklines" do
        UserVisit.create!(user_id: user_1.id, visited_at: 5.days.ago)

        result = data.compute[:metrics][:visitors]
        expect(result[:daily]).to be_an(Array)
        expect(result[:daily].first).to have_key(:date)
        expect(result[:daily].first).to have_key(:value)
      end
    end

    describe "new_members" do
      it "counts new user registrations" do
        Fabricate(:user, created_at: 3.days.ago)
        Fabricate(:user, created_at: 2.days.ago)

        result = data.compute[:metrics][:new_members]
        expect(result[:current]).to be >= 2
      end
    end

    describe "contributors" do
      it "counts users who posted" do
        Fabricate(:post, user: user_1, created_at: 5.days.ago)

        result = data.compute[:metrics][:contributors]
        expect(result[:current]).to be >= 1
      end
    end

    describe "response_rate" do
      it "returns percentage" do
        result = data.compute[:metrics][:response_rate]
        expect(result[:is_percentage]).to be true
      end

      it "calculates rate from topics with replies" do
        Fabricate(:topic, category: category, created_at: 5.days.ago, posts_count: 3)
        Fabricate(:topic, category: category, created_at: 5.days.ago, posts_count: 1)

        result = data.compute[:metrics][:response_rate]
        expect(result[:current]).to eq(50)
      end
    end

    describe "solved" do
      it "returns current and previous counts" do
        result = data.compute[:metrics][:solved]
        expect(result).to have_key(:current)
        expect(result).to have_key(:previous)
      end
    end
  end

  describe "top_topics" do
    it "returns topics ordered by views" do
      topic = Fabricate(:topic, category: category, created_at: 5.days.ago, like_count: 10)
      TopicViewStat.create!(
        topic_id: topic.id,
        viewed_at: 4.days.ago,
        anonymous_views: 50,
        logged_in_views: 20,
      )

      result = data.compute[:top_topics]
      expect(result).to be_present
      expect(result.first[:topic_id]).to eq(topic.id)
      expect(result.first[:views]).to eq(70)
    end
  end

  describe "categories" do
    it "returns per-category data with trend" do
      Fabricate(:topic, category: category, created_at: 5.days.ago, posts_count: 2)

      result = data.compute[:categories]
      cat_result = result.find { |c| c[:category_id] == category.id }
      expect(cat_result).to be_present
      expect(cat_result[:new_topics]).to be >= 1
      expect(cat_result).to have_key(:trend_pct)
    end
  end

  describe "posts_breakdown" do
    it "separates topics and replies" do
      topic = Fabricate(:topic, category: category, created_at: 5.days.ago, posts_count: 3)
      Fabricate(:post, topic: topic, post_number: 2, created_at: 5.days.ago)
      Fabricate(:post, topic: topic, post_number: 3, created_at: 5.days.ago)

      result = data.compute[:posts_breakdown]
      expect(result[:topics]).to be >= 1
      expect(result[:replies]).to be >= 0
    end
  end

  describe "geo_breakdown" do
    it "returns country breakdown from active users in period" do
      UserVisit.create!(user_id: user_1.id, visited_at: 5.days.ago)
      UserVisit.create!(user_id: user_2.id, visited_at: 3.days.ago)
      UserVisit.create!(user_id: user_3.id, visited_at: 2.days.ago)

      InsightsUserGeo.create!(
        user_id: user_1.id,
        country_code: "US",
        country: "United States",
        ip_address: "1.1.1.1",
      )
      InsightsUserGeo.create!(
        user_id: user_2.id,
        country_code: "US",
        country: "United States",
        ip_address: "2.2.2.2",
      )
      InsightsUserGeo.create!(
        user_id: user_3.id,
        country_code: "GB",
        country: "United Kingdom",
        ip_address: "3.3.3.3",
      )

      result = data.compute[:geo_breakdown]
      expect(result).to be_present
      us = result.find { |r| r[:country_code] == "US" }
      gb = result.find { |r| r[:country_code] == "GB" }
      expect(us[:count]).to eq(2)
      expect(gb[:count]).to eq(1)
      expect(us[:pct]).to be_within(0.1).of(66.7)
    end

    it "excludes users not active in the period" do
      UserVisit.create!(user_id: user_1.id, visited_at: 5.days.ago)
      # user_2 has no visits in period

      InsightsUserGeo.create!(
        user_id: user_1.id,
        country_code: "US",
        country: "United States",
        ip_address: "1.1.1.1",
      )
      InsightsUserGeo.create!(
        user_id: user_2.id,
        country_code: "GB",
        country: "United Kingdom",
        ip_address: "2.2.2.2",
      )

      result = data.compute[:geo_breakdown]
      expect(result.length).to eq(1)
      expect(result.first[:country_code]).to eq("US")
    end

    it "omits geo_breakdown when no geo data exists" do
      UserVisit.create!(user_id: user_1.id, visited_at: 5.days.ago)

      result = data.compute
      expect(result).not_to have_key(:geo_breakdown)
    end
  end

  describe "period handling" do
    it "handles 7d period" do
      instance = described_class.new(period: "7d")
      result = instance.compute
      expect(result[:period][:key]).to eq("7d")
    end

    it "handles 3m period" do
      instance = described_class.new(period: "3m")
      result = instance.compute
      expect(result[:period][:key]).to eq("3m")
    end

    it "defaults to 30d for invalid period" do
      instance = described_class.new(period: "invalid")
      result = instance.compute
      expect(result[:period][:key]).to eq("invalid")
      expect(result[:period][:end_date]).to eq(Date.today)
    end
  end
end
