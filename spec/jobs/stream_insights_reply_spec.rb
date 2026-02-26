# frozen_string_literal: true

describe Jobs::StreamInsightsReply do
  fab!(:user)

  before do
    enable_current_plugin
    skip("discourse-ai not available") unless defined?(DiscourseAi)
    SiteSetting.discourse_ai_enabled = true
  end

  it "publishes streamed AI reply to MessageBus" do
    persona =
      AiPersona.find_or_create_by!(name: DiscourseInsights::AI_PERSONA_NAME) do |p|
        p.system_prompt = "test"
        p.allowed_group_ids = [Group::AUTO_GROUPS[:staff]]
      end
    llm = LlmModel.first || Fabricate(:llm_model)
    persona.update!(default_llm_id: llm.id)

    bot_instance = instance_double(DiscourseAi::Personas::Bot)
    allow(DiscourseAi::Personas::Bot).to receive(:as).and_return(bot_instance)
    allow(bot_instance).to receive(:reply) do |_context, &block|
      block.call("Hello ", nil, nil)
      block.call("world", nil, nil)
    end

    messages =
      MessageBus.track_publish("/insights/ai/stream") do
        described_class.new.execute(
          user_id: user.id,
          type: "summary",
          period_opts: {
            "period" => "30d",
          },
        )
      end

    expect(messages).to be_present

    last_msg = messages.last
    expect(last_msg.data[:done]).to eq(true)
    expect(last_msg.data[:text]).to eq("Hello world")
    expect(last_msg.data[:type]).to eq("summary")
    expect(last_msg.user_ids).to eq([user.id])
  end

  it "returns early if user not found" do
    expect {
      described_class.new.execute(user_id: -999, type: "summary", period_opts: { "period" => "30d" })
    }.not_to raise_error
  end

  it "returns early if persona not found" do
    AiPersona.where(name: DiscourseInsights::AI_PERSONA_NAME).delete_all

    expect {
      described_class.new.execute(
        user_id: user.id,
        type: "summary",
        period_opts: {
          "period" => "30d",
        },
      )
    }.not_to raise_error
  end
end
