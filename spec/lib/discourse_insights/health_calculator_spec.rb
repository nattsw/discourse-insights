# frozen_string_literal: true

describe DiscourseInsights::HealthCalculator do
  fab!(:user_1, :user)
  fab!(:user_2, :user)
  fab!(:user_3, :user)
  fab!(:category)

  let(:start_date) { 30.days.ago.to_date }
  let(:end_date) { Date.today }
  let(:calculator) { described_class.new(start_date: start_date, end_date: end_date) }

  before { enable_current_plugin }

  describe "#compute" do
    it "returns the expected top-level keys" do
      result = calculator.compute
      expect(result).to have_key(:health_score)
      expect(result).to have_key(:funnel)
      expect(result).to have_key(:lifecycle)
      expect(result).to have_key(:attention_items)
      expect(result).to have_key(:top_content)
      expect(result).to have_key(:category_health)
    end
  end

  describe "health score" do
    it "returns overall score with dimensions" do
      UserVisit.create!(user_id: user_1.id, visited_at: 5.days.ago)

      result = calculator.compute[:health_score]
      expect(result[:overall]).to be_a(Integer)
      expect(result[:label]).to be_present
      expect(result[:dimensions]).to have_key(:activity)
      expect(result[:dimensions]).to have_key(:growth)
      expect(result[:dimensions]).to have_key(:engagement)
      expect(result[:dimensions]).to have_key(:content)
      expect(result[:dimensions]).to have_key(:responsiveness)
    end

    it "scores content higher when more topics have replies" do
      3.times { Fabricate(:topic, category: category, created_at: 5.days.ago, posts_count: 3) }
      Fabricate(:topic, category: category, created_at: 5.days.ago, posts_count: 1)

      result = calculator.compute[:health_score]
      expect(result[:dimensions][:content][:score]).to be > 0
    end
  end

  describe "funnel" do
    it "counts logged-in users who visited" do
      UserVisit.create!(user_id: user_1.id, visited_at: 5.days.ago, posts_read: 3)
      UserVisit.create!(user_id: user_2.id, visited_at: 3.days.ago, posts_read: 0)

      result = calculator.compute[:funnel]
      expect(result[:logged_in]).to eq(2)
      expect(result[:readers]).to eq(1)
    end

    it "counts posters" do
      Fabricate(:post, user: user_1, created_at: 5.days.ago)

      result = calculator.compute[:funnel]
      expect(result[:posters]).to eq(1)
    end
  end

  describe "lifecycle" do
    it "classifies returning users" do
      existing_user = Fabricate(:user, created_at: 90.days.ago)
      UserVisit.create!(user_id: existing_user.id, visited_at: 5.days.ago)
      UserVisit.create!(user_id: existing_user.id, visited_at: 35.days.ago)

      result = calculator.compute[:lifecycle]
      expect(result[:returning]).to eq(1)
    end

    it "classifies new users" do
      new_user = Fabricate(:user, created_at: 3.days.ago)
      UserVisit.create!(user_id: new_user.id, visited_at: 3.days.ago)

      result = calculator.compute[:lifecycle]
      expect(result[:new]).to eq(1)
    end

    it "classifies churned users" do
      # active only in prior period
      UserVisit.create!(user_id: user_2.id, visited_at: 35.days.ago)

      result = calculator.compute[:lifecycle]
      expect(result[:churned]).to eq(1)
    end
  end

  describe "attention items" do
    it "detects unanswered topics" do
      Fabricate(:topic, category: category, created_at: 2.days.ago, posts_count: 1, visible: true)

      result = calculator.compute[:attention_items]
      unanswered = result.select { |i| i[:type] == "unanswered_topics" }
      expect(unanswered).to be_present
      expect(unanswered.first[:count]).to eq(1)
    end

    it "detects inactive categories" do
      empty_cat = Fabricate(:category, topic_count: 5)

      result = calculator.compute[:attention_items]
      inactive = result.select { |i| i[:type] == "inactive_category" }
      expect(inactive.map { |i| i[:category] }).to include(empty_cat.name)
    end
  end

  describe "top content" do
    it "returns topics ordered by engagement" do
      topic = Fabricate(:topic, category: category, created_at: 5.days.ago, like_count: 10)
      TopicViewStat.create!(
        topic_id: topic.id,
        viewed_at: 4.days.ago,
        anonymous_views: 50,
        logged_in_views: 20,
      )

      result = calculator.compute[:top_content]
      expect(result).to be_present
      expect(result.first[:topic_id]).to eq(topic.id)
    end
  end

  describe "category health" do
    it "returns per-category health scores" do
      topic = Fabricate(:topic, category: category, created_at: 5.days.ago, posts_count: 2)
      Fabricate(:post, topic: topic, post_number: 2, created_at: 5.days.ago + 1.hour)

      result = calculator.compute[:category_health]
      cat_result = result.find { |c| c[:category_id] == category.id }
      expect(cat_result).to be_present
      expect(cat_result[:reply_rate]).to eq(100)
      expect(cat_result[:health_score]).to be_a(Integer)
    end
  end
end
