# frozen_string_literal: true

describe Jobs::NotifyInsightsFeedback do
  fab!(:admin)
  fab!(:notify_group) { Fabricate(:group) }

  before { SiteSetting.insights_enabled = true }

  def create_feedback(user, comment)
    InsightsFeedback.create!(user: user, comment: comment)
  end

  it "sends a PM with pending feedback to the configured group" do
    SiteSetting.insights_feedback_notify_group = notify_group.id.to_s

    fb1 = create_feedback(admin, "Love the charts")
    fb2 = create_feedback(Fabricate(:user), "Needs dark mode")

    expect { described_class.new.execute({}) }.to change {
      Topic.where(archetype: Archetype.private_message).count
    }.by(1)

    topic = Topic.where(archetype: Archetype.private_message).order(:id).last
    expect(topic.first_post.user).to eq(Discourse.system_user)
    expect(topic.first_post.raw).to include("Love the charts")
    expect(topic.first_post.raw).to include("Needs dark mode")
    expect(topic.topic_allowed_groups.map(&:group_id)).to include(notify_group.id)

    expect(fb1.reload.notified).to eq(true)
    expect(fb2.reload.notified).to eq(true)
  end

  it "does not send a PM when there is no pending feedback" do
    SiteSetting.insights_feedback_notify_group = notify_group.id.to_s

    expect { described_class.new.execute({}) }.not_to change {
      Topic.where(archetype: Archetype.private_message).count
    }
  end

  it "does not send a PM when no notify group is configured" do
    SiteSetting.insights_feedback_notify_group = ""
    create_feedback(admin, "Some feedback")

    expect { described_class.new.execute({}) }.not_to change {
      Topic.where(archetype: Archetype.private_message).count
    }
  end

  it "skips already-notified feedback" do
    SiteSetting.insights_feedback_notify_group = notify_group.id.to_s

    create_feedback(admin, "Old feedback").update!(notified: true)
    create_feedback(admin, "New feedback")

    described_class.new.execute({})

    topic = Topic.where(archetype: Archetype.private_message).order(:id).last
    expect(topic.first_post.raw).not_to include("Old feedback")
    expect(topic.first_post.raw).to include("New feedback")
  end

  it "does nothing when plugin is disabled" do
    SiteSetting.insights_enabled = false
    SiteSetting.insights_feedback_notify_group = notify_group.id.to_s
    create_feedback(admin, "Feedback")

    expect { described_class.new.execute({}) }.not_to change {
      Topic.where(archetype: Archetype.private_message).count
    }
  end
end
