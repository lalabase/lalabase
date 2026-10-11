# frozen_string_literal: true

require 'rails_helper'

# The org switcher tells a user that unread notifications wait in ANOTHER
# organisation: a dot on the header, the number next to that organisation in the
# menu (the same number its inbox shows). The inbox count itself stays per organisation (Notifications::Streams).
RSpec.describe 'Org switcher signal', :ci_guard, type: :request do
  let(:user) { create(:user) }
  let(:org_a) { create(:organisation, name: 'Alpha') }
  let(:org_b) { create(:organisation, name: 'Beta') }

  def join(org)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, role: create(:admin_role, organisation: org), active: true)
    end
  end

  def mention_in(org, event_type: 'mention')
    ActsAsTenant.with_tenant(org) do
      create(:notification, recipient: user, organisation: org, project: nil,
                            event_type: event_type, channel: 'in_app', state: :delivered)
    end
  end

  def sidebar_of(org)
    ActsAsTenant.current_tenant = org
    get organisation_notifications_path(org, state_filters: ['unread'])
    expect(response).to have_http_status(:ok), response.location.to_s
    Nokogiri::HTML5(response.body)
  end

  def dot(doc) = doc.at_css('#other_orgs_signal')
  def row_count(doc, org) = doc.at_css("#org_attention_count_#{org.id}")
  def shown?(node) = !node['class'].to_s.split.include?('hidden')

  before do
    join(org_a)
    join(org_b)
    sign_in user
    Prosopite.pause # Pre-existing N+1 in the inbox render path (see inbox_nav_count_stream_spec).
  end

  after { Prosopite.resume }

  it 'shows the dot and the count of the other organisation' do
    mention_in(org_b)
    mention_in(org_b, event_type: 'ticket_commented')

    doc = sidebar_of(org_a)

    expect(shown?(dot(doc))).to be(true)
    expect(dot(doc)['aria-label']).to eq(I18n.t('navigation.other_orgs_signal'))
    expect(shown?(row_count(doc, org_b))).to be(true)
    expect(row_count(doc, org_b).text.strip).to eq('2')
  end

  it 'puts the count of an organisation beyond the menu on "Alle Organisationen"' do
    stub_const('NavigationHelper::ORG_MENU_LIMIT', 2)
    org_c = create(:organisation, name: 'Gamma')
    join(org_c)
    mention_in(org_c)

    doc = sidebar_of(org_a)

    expect(shown?(dot(doc))).to be(true)
    expect(row_count(doc, org_c)).to be_nil
    expect(shown?(doc.at_css('#org_attention_count_overflow'))).to be(true)
    expect(doc.at_css('#org_attention_count_overflow').text.strip).to eq('1')
  end

  it 'shows no dot for the organisation the mention belongs to' do
    mention_in(org_b)

    doc = sidebar_of(org_b)

    expect(shown?(dot(doc))).to be(false)
    expect(row_count(doc, org_b)).to be_nil
  end

  it 'shows the dot for a comment, like the inbox counts it' do
    mention_in(org_b, event_type: 'ticket_commented')

    doc = sidebar_of(org_a)

    expect(shown?(dot(doc))).to be(true)
    expect(row_count(doc, org_b).text.strip).to eq('1')
  end

  it 'keeps the inbox count of the current organisation free of the other one' do
    mention_in(org_b)

    doc = sidebar_of(org_a)

    expect(doc.at_css('turbo-frame#notification_count_data')['data-notification-count-data-count-value']).to eq('0')
  end

  it 'subscribes to the badge stream of the current organisation only' do
    doc = sidebar_of(org_a)

    signed = doc.css('turbo-cable-stream-source').map { |n| n['signed-stream-name'] }
    names = signed.map { |s| Turbo::StreamsChannel.verified_stream_name(s) }
    expect(names).to include(Notifications::Streams.badge(user, org_a))
    expect(names.join).not_to include(org_b.id.to_s)
  end

  # The broadcast, applied to the real sidebar the way Turbo applies a replace:
  # the dot appears, then disappears again once the mention is read.
  it 'turns the dot on and off live' do
    doc = sidebar_of(org_a)
    expect(shown?(dot(doc))).to be(false)

    apply = lambda do
      html = []
      allow(ActionCable.server).to receive(:broadcast) do |stream, payload|
        html << payload if stream == Notifications::Streams.badge(user, org_a)
      end
      Notifications::UnreadSignals.call(user: user)
      Nokogiri::HTML5.fragment(html.join).css('turbo-stream[action="replace"]').each do |stream|
        target = doc.at_css("##{stream['target']}")
        expect(target).not_to be_nil, "no target ##{stream['target']} in the sidebar"
        target.replace(stream.at_css('template').children)
      end
    end

    notification = mention_in(org_b)
    apply.call
    expect(shown?(dot(doc))).to be(true)
    expect(row_count(doc, org_b).text.strip).to eq('1')

    ActsAsTenant.with_tenant(org_b) { notification.mark_as_read! }
    apply.call
    expect(shown?(dot(doc))).to be(false)
    expect(shown?(row_count(doc, org_b))).to be(false)
  end

  describe 'bulk writers refresh the signal' do
    before { ActiveJob::Base.queue_adapter = :test }

    it 'mark_all_read in the other organisation' do
      mention_in(org_b)
      ActsAsTenant.current_tenant = org_b

      expect do
        patch mark_all_read_organisation_notifications_path(org_b), as: :turbo_stream
      end.to have_enqueued_job(Notifications::UnreadSignalsJob).with(user_id: user.id)
    end

    it 'archive_all of selected unread notifications' do
      notification = mention_in(org_b)
      ActsAsTenant.current_tenant = org_b

      expect do
        patch archive_all_organisation_notifications_path(org_b), params: { ids: [notification.id] }, as: :turbo_stream
      end.to have_enqueued_job(Notifications::UnreadSignalsJob).with(user_id: user.id)
    end
  end
end
