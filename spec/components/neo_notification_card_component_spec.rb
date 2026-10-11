# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NeoNotificationCardComponent, type: :component do
  # Setup
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:actor) { create(:user, organisation: organisation, first_name: 'John', last_name: 'Doe') }
  let(:project) { create(:project, organisation: organisation, name: 'Test Project') }
  let(:ticket) { create(:ticket, project: project, number: 123, title: 'Test Ticket') }

  let(:notification) do
    create(:notification,
           recipient: user,
           actor: actor,
           notifiable: ticket,
           organisation: organisation,
           project: project,
           event_type: 'ticket_assigned',
           payload: { test_data: 'value' })
  end

  before do
    ActsAsTenant.current_tenant = organisation

    # Mock I18n for predictable testing. The catch-all must come first: the component looks up
    # more keys than the two stubbed below (e.g. components.neo_notification_card.event_labels.*),
    # and without a default the partial double turns every unlisted key into a failure — which is
    # what happened when the event-label lookup was added to the component.
    allow(I18n).to receive(:t).and_call_original
    allow(I18n).to receive(:t).with('notifications.titles.ticket_assigned', default: 'Ticket assigned')
                              .and_return('Ticket assigned')
    allow(I18n).to receive(:t).with(
      'notifications.messages.ticket_assigned',
      actor: 'John Doe',
      notifiable: '#123 Test Ticket',
      test_data: 'value'
    ).and_return('John Doe assigned you to #123 Test Ticket')
  end

  describe 'rendering' do
    subject { render_inline(described_class.new(notification: notification)) }

    it 'renders the component' do
      expect(subject.to_html).to be_present
    end

    it 'includes notification title' do
      expect(subject.to_html).to include('Ticket assigned')
    end

    it 'includes notification message' do
      expect(subject.to_html).to include('John Doe assigned you to #123 Test Ticket')
    end

    it 'includes event icon' do
      expect(subject.css('.bi-person-plus')).to be_present
    end

    it 'includes time information' do
      expect(subject.to_html).to include('ago') # from distance_of_time_in_words
    end

    it 'includes actor name' do
      expect(subject.to_html).to include('John Doe')
    end

    it 'includes project tag when show_project is true' do
      expect(subject.to_html).to include('Test Project')
    end
  end

  describe 'with show_project: false' do
    subject { render_inline(described_class.new(notification: notification, show_project: false)) }

    it 'does not include project tag' do
      expect(subject.to_html).not_to include('Test Project')
    end
  end

  describe 'render?' do
    it 'returns true when notification is present' do
      component = described_class.new(notification: notification)
      expect(component.render?).to be true
    end

    it 'returns false when notification is nil' do
      component = described_class.new(notification: nil)
      expect(component.render?).to be false
    end
  end

  describe '#notification_title' do
    let(:component) { described_class.new(notification: notification) }

    it 'returns translated title' do
      expect(component.send(:notification_title)).to eq('Ticket assigned')
    end
  end

  describe '#notification_message' do
    let(:component) { described_class.new(notification: notification) }

    context 'when notification is not grouped' do
      it 'returns non-grouped message' do
        # Render first: since S3 the actor name resolves through
        # helpers.viewer_display_name, and #helpers only exists once the
        # component entered the render pipeline.
        render_inline(component)

        expect(component.send(:notification_message)).to eq('John Doe assigned you to #123 Test Ticket')
      end
    end

    context 'when notification is grouped' do
      before do
        notification.update!(group_count: 3)
        # Pass-through base: the template's OTHER t() calls must keep working
        # during render — a bare `.with` stub raises on every non-matching call.
        allow(I18n).to receive(:t).and_call_original
        allow(I18n).to receive(:t).with(
          'notifications.messages.ticket_assigned_grouped',
          count: 3,
          actor: 'John Doe',
          notifiable: '#123 Test Ticket',
          test_data: 'value'
        ).and_return('John Doe made 3 assignments including #123 Test Ticket')
      end

      it 'returns grouped message' do
        render_inline(component)

        expect(component.send(:notification_message)).to eq('John Doe made 3 assignments including #123 Test Ticket')
      end
    end

    context 'when I18n raises error' do
      before do
        exception = I18n::MissingInterpolationArgument.new(:missing_key, {}, 'translation')
        # Only the message lookup blows up — that is what a payload/event_type mismatch does in
        # production. Raising on EVERY I18n.t would also sabotage fallback_message, which the
        # rescue path itself calls, and the exception would escape the component (a sibling
        # `rescue Exception` cannot catch what another rescue clause raises).
        allow(I18n).to receive(:t)
          .with("notifications.messages.#{notification.event_type}", any_args)
          .and_raise(exception)
        allow(Rails.logger).to receive(:warn)
      end

      it 'returns fallback message' do
        result = component.send(:notification_message)
        expect(result).to eq('Benachrichtigung: John Doe hat eine Aktion zu #123 Test Ticket durchgeführt')
      end
    end
  end

  describe '#event_icon' do
    let(:component) { described_class.new(notification: notification) }

    it 'returns correct icon for event type' do
      expect(component.send(:event_icon)).to eq('person-plus')
    end

    context 'with unknown event type' do
      before do
        allow(notification).to receive(:event_type).and_return('unknown_event')
      end

      it 'returns default icon' do
        expect(component.send(:event_icon)).to eq('bell')
      end
    end
  end

  describe '#notification_url' do
    let(:component) { described_class.new(notification: notification) }
    let(:helpers_double) { double(notification_deeplink_path: '/notifications/open/123') }

    before do
      allow(component).to receive(:helpers).and_return(helpers_double)
    end

    it 'delegates to notification deeplink helper' do
      expect(component.send(:notification_url)).to eq('/notifications/open/123')
    end

    context 'when notification has action_url but deeplink unavailable' do
      before do
        allow(helpers_double).to receive(:notification_deeplink_path).and_return('#')
        allow(component).to receive(:fallback_notifiable_url).and_return(nil)

        def notification.action_url
          '/custom/action/url'
        end
      end

      it 'falls back to notification action_url' do
        expect(component.send(:notification_url)).to eq('/custom/action/url')
      end
    end
  end

  describe '#grouped_count_text' do
    let(:component) { described_class.new(notification: notification) }

    context 'when group_count is 1' do
      it 'returns nil' do
        expect(component.send(:grouped_count_text)).to be_nil
      end
    end

    context 'when group_count is 2' do
      before { notification.update!(group_count: 2) }

      it 'returns singular text' do
        expect(component.send(:grouped_count_text)).to eq('und 1 weitere Aktivität')
      end
    end

    context 'when group_count is more than 2' do
      before { notification.update!(group_count: 5) }

      it 'returns plural text' do
        expect(component.send(:grouped_count_text)).to eq('und 4 weitere Aktivitäten')
      end
    end
  end

  describe '#ticket_accessible?' do
    let(:component) { described_class.new(notification: notification) }

    before do
      allow(component).to receive(:helpers).and_return(double(current_user: user))
    end

    context 'when notification is not for a ticket' do
      let(:notification) { create(:notification, recipient: user, notifiable: project, organisation: organisation) }

      it 'returns false' do
        expect(component.send(:ticket_accessible?)).to be false
      end
    end

    context 'when notification is for a ticket' do
      before do
        # Mock TicketPolicy
        policy_double = double(show?: true)
        allow(TicketPolicy).to receive(:new).with(user, ticket).and_return(policy_double)
      end

      it 'returns true when user has access' do
        expect(component.send(:ticket_accessible?)).to be true
      end

      context 'when user does not have access' do
        before do
          policy_double = double(show?: false)
          allow(TicketPolicy).to receive(:new).with(user, ticket).and_return(policy_double)
        end

        it 'returns false' do
          expect(component.send(:ticket_accessible?)).to be false
        end
      end

      context 'when policy raises error' do
        before do
          allow(TicketPolicy).to receive(:new).and_raise(StandardError.new('Policy error'))
          allow(Rails.logger).to receive(:warn)
        end

        it 'returns false and logs warning' do
          expect(component.send(:ticket_accessible?)).to be false
          expect(Rails.logger).to have_received(:warn)
        end
      end
    end
  end

  describe '#ticket_exists_and_accessible?' do
    let(:component) { described_class.new(notification: notification) }

    before do
      allow(component).to receive(:helpers).and_return(double(current_user: user))
    end

    context 'when notification is not for a ticket' do
      let(:notification) { create(:notification, recipient: user, notifiable: project, organisation: organisation) }

      it 'returns false' do
        expect(component.send(:ticket_exists_and_accessible?)).to be false
      end
    end

    context 'when ticket is deleted' do
      before do
        allow(notification).to receive(:notifiable).and_return(nil)
      end

      it 'returns false' do
        expect(component.send(:ticket_exists_and_accessible?)).to be false
      end
    end

    context 'when ticket exists and is accessible' do
      before do
        allow(component).to receive(:ticket_accessible?).and_return(true)
      end

      it 'returns true' do
        expect(component.send(:ticket_exists_and_accessible?)).to be true
      end
    end
  end

  describe 'CSS classes and styling' do
    subject { render_inline(described_class.new(notification: notification)) }

    it 'includes base notification card classes' do
      expect(subject.css('.neo-notification-card')).to be_present
    end

    it 'includes border classes' do
      expect(subject.css('.border-2.border-stroke')).to be_present
    end

    it 'includes hover effects' do
      expect(subject.css('[class*="hover:shadow"]')).to be_present
    end
  end

  describe 'priority indicators' do
    subject { render_inline(described_class.new(notification: notification)) }

    context 'when notification has high priority' do
      before { notification.update!(priority: 'high') }

      it 'includes priority indicator' do
        expect(subject.css('.bg-orange-400')).to be_present
      end
    end

    context 'when notification has critical priority' do
      before { notification.update!(priority: 'critical') }

      it 'includes critical priority indicator' do
        expect(subject.css('.bg-red-500')).to be_present
      end
    end

    context 'when notification has normal priority' do
      it 'does not include priority indicator' do
        expect(subject.css('.bg-orange-400, .bg-red-500')).to be_empty
      end
    end
  end

  describe 'state-specific styling' do
    context 'when notification is read' do
      before { notification.update!(state: 'read') }

      subject { render_inline(described_class.new(notification: notification)) }

      it 'includes read state styling' do
        expect(subject.css('.bg-gray-50')).to be_present
      end
    end

    context 'when notification is archived' do
      before { notification.update!(state: 'archived') }

      subject { render_inline(described_class.new(notification: notification)) }

      it 'includes archived state styling' do
        expect(subject.css('.bg-gray-100')).to be_present
      end
    end
  end

  describe 'integration with different notifiable types' do
    context 'with Project notifiable' do
      let(:notification) { create(:notification, recipient: user, notifiable: project, organisation: organisation) }

      subject { render_inline(described_class.new(notification: notification)) }

      it 'renders without errors' do
        expect(subject.to_html).to be_present
      end
    end

    context 'with Document notifiable' do
      let(:document) do
        doc = create(:document, project: project, organisation: organisation)
        version = build(:document_version, document: doc, organisation: organisation, title: 'Test Document')
        doc.current_version = version
        doc
      end
      let(:notification) { create(:notification, recipient: user, notifiable: document, organisation: organisation) }

      subject { render_inline(described_class.new(notification: notification)) }

      it 'renders without errors' do
        expect(subject.to_html).to be_present
      end
    end
  end
end
