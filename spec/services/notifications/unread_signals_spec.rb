# frozen_string_literal: true

require 'rails_helper'

# The org switcher dot: unread notifications in the user's OTHER organisations,
# counted exactly like the inbox count of that organisation.
RSpec.describe Notifications::UnreadSignals, :ci_guard do
  let(:user) { create(:user) }
  let(:org_a) { create(:organisation, name: 'Org A') }
  let(:org_b) { create(:organisation, name: 'Org B') }
  let(:org_c) { create(:organisation, name: 'Org C') }

  def join(org, admin: true)
    ActsAsTenant.with_tenant(org) do
      role = admin ? create(:admin_role, organisation: org) : create(:role, organisation: org)
      create(:membership, user: user, organisation: org, role: role, active: true)
    end
  end

  # Setup only: factory saves are not the code under test for Prosopite.
  def notify(org, event_type:, state: :delivered, channel: 'in_app', project: nil)
    Prosopite.pause
    ActsAsTenant.with_tenant(org) do
      create(:notification, recipient: user, organisation: org, project: project,
                            event_type: event_type, state: state, channel: channel)
    end
  ensure
    Prosopite.resume
  end

  before do
    join(org_a)
    join(org_b)
  end

  describe '.counts_for' do
    it 'counts the unread notifications of the other organisations' do
      notify(org_b, event_type: 'mention')
      notify(org_b, event_type: 'ticket_commented')

      expect(described_class.counts_for(user, except: org_a)).to eq(org_b.id => 2)
    end

    it 'leaves out the current organisation' do
      notify(org_a, event_type: 'mention')

      expect(described_class.counts_for(user, except: org_a)).to eq({})
    end

    # Until 29.09.2026 only mentions and assignments counted, and the menu
    # showed a smaller number than the inbox the user switched to.
    it 'counts every event type the inbox counts' do
      Notifications::Constants::VALID_EVENT_TYPES.each { |type| notify(org_b, event_type: type) }

      expect(described_class.counts_for(user, except: org_a))
        .to eq(org_b.id => Notifications::Constants::VALID_EVENT_TYPES.size)
    end

    # One rule for "unread": the number next to an organisation is the number
    # its inbox shows after the switch.
    it 'equals the inbox count of each other organisation' do
      join(org_c, admin: false)
      hidden = ActsAsTenant.with_tenant(org_c) { create(:project, organisation: org_c) }
      notify(org_b, event_type: 'ticket_status_changed')
      notify(org_b, event_type: 'mention', state: :read)
      notify(org_c, event_type: 'ticket_commented')
      notify(org_c, event_type: 'document_added', project: hidden)

      counts = described_class.counts_for(user, except: org_a)

      [org_b, org_c].each do |org|
        inbox = ActsAsTenant.with_tenant(org) { user.unread_notifications_count(org) }
        expect(counts.fetch(org.id, 0)).to eq(inbox), org.name
      end
    end

    it 'ignores read, archived and email notifications' do
      notify(org_b, event_type: 'mention', state: :read)
      notify(org_b, event_type: 'mention', state: :archived)
      notify(org_b, event_type: 'mention', channel: 'email')

      expect(described_class.counts_for(user, except: org_a)).to eq({})
    end

    it 'counts queued, sent and delivered as unread' do
      %i[queued sent delivered].each { |state| notify(org_b, event_type: 'mention', state: state) }

      expect(described_class.counts_for(user, except: org_a)).to eq(org_b.id => 3)
    end

    it 'ignores organisations the user is no longer an active member of' do
      join(org_c)
      notify(org_c, event_type: 'mention')
      ActsAsTenant.with_tenant(org_c) { Membership.find_by!(user: user, organisation: org_c).update!(active: false) }

      expect(described_class.counts_for(user, except: org_a)).to eq({})
    end

    it 'ignores mentions in projects the user cannot access' do
      join(org_c, admin: false)
      hidden = ActsAsTenant.with_tenant(org_c) { create(:project, organisation: org_c) }
      notify(org_c, event_type: 'mention', project: hidden)
      notify(org_c, event_type: 'mention')

      expect(described_class.counts_for(user, except: org_a)).to eq(org_c.id => 1)
    end
  end

  describe '.call' do
    let(:rendered) { [] }

    before do
      allow(Turbo::StreamsChannel).to receive(:broadcast_render_to) { |stream, **opts| rendered << [stream, opts] }
    end

    it 'sends every organisation its own view, without itself' do
      join(org_c)
      notify(org_b, event_type: 'mention')
      notify(org_c, event_type: 'ticket_commented')

      described_class.call(user: user)

      by_stream = rendered.to_h { |stream, opts| [stream, opts[:locals][:counts]] }
      expect(by_stream).to eq(
        Notifications::Streams.badge(user, org_a) => { org_b.id => 1, org_c.id => 1 },
        Notifications::Streams.badge(user, org_b) => { org_c.id => 1 },
        Notifications::Streams.badge(user, org_c) => { org_b.id => 1 }
      )
    end

    it 'names every other organisation, so a count that dropped to zero is cleared' do
      described_class.call(user: user)

      org_ids = rendered.to_h { |stream, opts| [stream, opts[:locals][:organisation_ids]] }
      expect(org_ids[Notifications::Streams.badge(user, org_a)]).to eq([org_b.id])
      expect(org_ids[Notifications::Streams.badge(user, org_b)]).to eq([org_a.id])
    end

    it 'counts organisations beyond the menu on "Alle Organisationen", not as rows' do
      stub_const('NavigationHelper::ORG_MENU_LIMIT', 2)
      join(org_c)
      notify(org_c, event_type: 'mention')

      described_class.call(user: user)

      locals = rendered.to_h { |stream, opts| [stream, opts[:locals]] }[Notifications::Streams.badge(user, org_a)]
      expect(locals[:organisation_ids]).to eq([org_b.id])
      expect(locals[:overflow_count]).to eq(1)
    end

    it 'sends nothing to a user with a single organisation' do
      single = create(:user)
      ActsAsTenant.with_tenant(org_a) do
        create(:membership, user: single, organisation: org_a, role: create(:role, organisation: org_a))
      end

      described_class.call(user: single)

      expect(rendered).to be_empty
    end

    it 'renders the streams in the language of the user' do
      user.update!(language_preference: 'en')
      notify(org_b, event_type: 'mention')
      allow(Turbo::StreamsChannel).to receive(:broadcast_render_to).and_call_original
      html = []
      allow(ActionCable.server).to receive(:broadcast) { |_stream, payload| html << payload }

      described_class.call(user: user)

      expect(html.join).to include(I18n.t('navigation.other_orgs_signal', locale: :en))
    end
  end

  describe '.refresh_later' do
    before { ActiveJob::Base.queue_adapter = :test }

    it 'enqueues the job for the user' do
      expect { described_class.refresh_later(user) }
        .to have_enqueued_job(Notifications::UnreadSignalsJob).with(user_id: user.id)
    end
  end
end
