# frozen_string_literal: true

describe Jobs::ResolveUserGeos do
  fab!(:user) { Fabricate(:user, ip_address: "8.8.8.8") }
  fab!(:user_without_ip) { Fabricate(:user, ip_address: nil) }

  let(:geo_info) do
    {
      country_code: "US",
      country: "United States",
      region: "California",
      city: "Mountain View",
      latitude: 37.386,
      longitude: -122.0838,
    }
  end

  before do
    SiteSetting.insights_enabled = true
    allow(DiscourseIpInfo).to receive(:get).and_call_original
    allow(DiscourseIpInfo).to receive(:get).with("8.8.8.8").and_return(geo_info)
  end

  it "creates geo records for users with IPs" do
    described_class.new.execute({})

    geo = InsightsUserGeo.find_by(user_id: user.id)
    expect(geo).to be_present
    expect(geo.country_code).to eq("US")
    expect(geo.country).to eq("United States")
    expect(geo.region).to eq("California")
    expect(geo.city).to eq("Mountain View")
    expect(geo.latitude).to be_within(0.01).of(37.386)
    expect(geo.longitude).to be_within(0.01).of(-122.0838)
    expect(geo.ip_address.to_s).to eq("8.8.8.8")
  end

  it "skips users without an IP address" do
    described_class.new.execute({})

    expect(InsightsUserGeo.find_by(user_id: user_without_ip.id)).to be_nil
  end

  it "updates geo when user IP changes" do
    described_class.new.execute({})

    new_info = geo_info.merge(country_code: "GB", country: "United Kingdom", region: "England")
    allow(DiscourseIpInfo).to receive(:get).with("1.2.3.4").and_return(new_info)

    user.update_columns(ip_address: "1.2.3.4")
    described_class.new.execute({})

    geo = InsightsUserGeo.find_by(user_id: user.id)
    expect(geo.country_code).to eq("GB")
    expect(geo.ip_address.to_s).to eq("1.2.3.4")
  end

  it "does not re-resolve when IP has not changed" do
    described_class.new.execute({})

    expect(DiscourseIpInfo).to have_received(:get).with("8.8.8.8").once

    described_class.new.execute({})

    # still only called once — second run skips this user
    expect(DiscourseIpInfo).to have_received(:get).with("8.8.8.8").once
  end

  it "does nothing when plugin is disabled" do
    SiteSetting.insights_enabled = false
    described_class.new.execute({})

    expect(InsightsUserGeo.count).to eq(0)
  end

  it "skips IPs that MaxMind cannot resolve" do
    allow(DiscourseIpInfo).to receive(:get).with("8.8.8.8").and_return({})
    described_class.new.execute({})

    expect(InsightsUserGeo.find_by(user_id: user.id)).to be_nil
  end

  it "handles multiple users sharing the same IP" do
    user2 = Fabricate(:user, ip_address: "8.8.8.8")
    described_class.new.execute({})

    expect(InsightsUserGeo.find_by(user_id: user.id)).to be_present
    expect(InsightsUserGeo.find_by(user_id: user2.id)).to be_present

    # only one MaxMind lookup for the shared IP
    expect(DiscourseIpInfo).to have_received(:get).with("8.8.8.8").once
  end
end
