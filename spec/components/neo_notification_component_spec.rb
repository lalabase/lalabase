# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NeoNotificationComponent, type: :component do
  # Setup
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:actor) { create(:user, organisation: organisation, first_name: 'Jane', last_name: 'Smith') }
  let(:project) { create(:project, organisation: organisation, name: 'Demo Project') }
  let(:ticket) { create(:ticket, project: project, number: 456, title: 'Demo Ticket') }

  let(:notification) do
    create(:notification,
           recipient: user,
           actor: actor,
           notifiable: ticket,
           organisation: organisation,
           event_type: 'ticket_commented',
           payload: { comment_text: 'Test comment' })
  end

  before do
    ActsAsTenant.current_tenant = organisation

    # Mock I18n for predictable testing
    allow(I18n).to receive(:t).with(
      'notifications.messages.ticket_commented',
      actor: 'Jane Smith',
      notifiable: '#456 Demo Ticket',
      comment_text: 'Test comment'
    ).and_return('Jane Smith commented on #456 Demo Ticket')
  end

  describe 'initialization' do
    it 'sets default values' do
      component = described_class.new(notification: notification)

      expect(component.notification).to eq(notification)
      expect(component.variant).to eq(:default)
      expect(component.show_avatar).to be true
      expect(component.show_actions).to be true
      expect(component.clickable).to be true
    end

    it 'accepts custom parameters' do
      component = described_class.new(
        notification: notification,
        variant: :compact,
        show_avatar: false,
        show_actions: false,
        clickable: false
      )

      expect(component.variant).to eq(:compact)
      expect(component.show_avatar).to be false
      expect(component.show_actions).to be false
      expect(component.clickable).to be false
    end
  end

  describe 'rendering' do
    subject { render_inline(described_class.new(notification: notification)) }

    it 'renders the component' do
      expect(subject.to_html).to be_present
    end

    it 'includes notification message' do
      expect(subject.to_html).to include('Jane Smith commented on #456 Demo Ticket')
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

  describe '#notification_classes' do
    let(:component) { described_class.new(notification: notification) }

    it 'includes base class' do
      expect(component.send(:notification_classes)).to include('notification-item')
    end

    context 'when notification is unread' do
      it 'includes unread class' do
        expect(component.send(:notification_classes)).to include('notification-item--unread')
      end
    end

    context 'when notification is read' do
      before { notification.update!(state: 'read') }

      it 'does not include unread class' do
        expect(component.send(:notification_classes)).not_to include('notification-item--unread')
      end
    end

    context 'when notification is grouped' do
      before { notification.update!(group_count: 3) }

      it 'includes grouped class' do
        expect(component.send(:notification_classes)).to include('notification-item--grouped')
      end
    end

    context 'with compact variant' do
      let(:component) { described_class.new(notification: notification, variant: :compact) }

      it 'includes variant class' do
        expect(component.send(:notification_classes)).to include('notification-item--compact')
      end
    end

    context 'when clickable with action_url' do
      before do
        allow(component).to receive(:action_url).and_return('/some/url')
      end

      it 'includes clickable class' do
        expect(component.send(:notification_classes)).to include('notification-item--clickable')
      end
    end
  end

  describe '#event_type_icon' do
    let(:component) { described_class.new(notification: notification) }

    it 'returns icon from constants' do
      expect(component.send(:event_type_icon)).to eq('chat-left-text')
    end

    context 'with unknown event type' do
      before do
        allow(notification).to receive(:event_type).and_return('unknown_event')
      end

      it 'returns default icon' do
        expect(component.send(:event_type_icon)).to eq('bell')
      end
    end
  end

  describe '#event_type_color' do
    let(:component) { described_class.new(notification: notification) }

    it 'returns color from constants' do
      expect(component.send(:event_type_color)).to eq('secondary')
    end

    context 'with unknown event type' do
      before do
        allow(notification).to receive(:event_type).and_return('unknown_event')
      end

      it 'returns default color' do
        expect(component.send(:event_type_color)).to eq('secondary')
      end
    end
  end

  describe 'actor avatar (S2: rendered through Neo::Users::NameComponent, no external service)' do
    it 'renders the actor initials chip' do
      render_inline(described_class.new(notification: notification))

      expect(page).to have_css('.notification-avatar span.neo-user-avatar[title="Jane Smith"]', text: 'JS')
    end

    it "renders an 'S' chip for a system event (nil actor)" do
      # Lift the argument-pinned I18n stub from the outer before block: with a
      # nil actor the message call has different arguments, and a partial
      # double raises on those (uncatchable by the component's rescue).
      allow(I18n).to receive(:t).and_call_original
      notification.update!(actor: nil)

      render_inline(described_class.new(notification: notification))

      expect(page).to have_css('.notification-avatar span.neo-user-avatar', text: 'S')
    end

    it 'never points at ui-avatars.com (the leak this replaced)' do
      render_inline(described_class.new(notification: notification))

      expect(page.native.to_html).not_to include('ui-avatars.com')
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

        expect(component.send(:notification_message)).to eq('Jane Smith commented on #456 Demo Ticket')
      end
    end

    context 'when notification is grouped' do
      before do
        notification.update!(group_count: 2)
        allow(I18n).to receive(:t).with(
          'notifications.messages.ticket_commented_grouped',
          count: 2,
          actor: 'Jane Smith',
          notifiable: '#456 Demo Ticket',
          comment_text: 'Test comment'
        ).and_return('Jane Smith made 2 comments on #456 Demo Ticket')
      end

      it 'returns grouped message' do
        render_inline(component)

        expect(component.send(:notification_message)).to eq('Jane Smith made 2 comments on #456 Demo Ticket')
      end
    end

    context 'when I18n raises MissingInterpolationArgument' do
      before do
        # Construct the exception with proper arguments (key, values, string)
        exception = I18n::MissingInterpolationArgument.new(:missing_key, {}, 'translation string')
        allow(I18n).to receive(:t).and_raise(exception)
        allow(Rails.logger).to receive(:warn)
      end

      it 'falls back to fallback message' do
        result = component.send(:notification_message)
        expect(result).to eq('Ticket commented notification')
        expect(Rails.logger).to have_received(:warn)
      end
    end

    context 'when other error occurs' do
      before do
        allow(I18n).to receive(:t).and_raise(StandardError.new('generic error'))
        allow(Rails.logger).to receive(:warn)
      end

      it 'falls back to fallback message' do
        result = component.send(:notification_message)
        expect(result).to eq('Ticket commented notification')
        expect(Rails.logger).to have_received(:warn)
      end
    end
  end

  describe '#time_ago_text' do
    let(:component) { described_class.new(notification: notification) }

    before do
      allow(component).to receive(:helpers).and_return(double(
                                                         time_ago_in_words: '2 hours'
                                                       ))
    end

    it 'returns time ago text from helper' do
      expect(component.send(:time_ago_text)).to eq('2 hours')
    end

    context 'when helper raises error' do
      before do
        allow(component).to receive(:helpers).and_raise(StandardError.new('helper error'))
        notification.update!(created_at: 2.days.ago)
      end

      it 'falls back to simple calculation' do
        expect(component.send(:time_ago_text)).to eq('2d ago')
      end
    end
  end

  describe '#group_count_text' do
    let(:component) { described_class.new(notification: notification) }

    context 'when notification is not grouped' do
      it 'returns nil' do
        expect(component.send(:group_count_text)).to be_nil
      end
    end

    context 'when notification is grouped' do
      before do
        notification.update!(group_count: 3)
        allow(component).to receive(:helpers).and_return(double(
                                                           pluralize: '3 updates'
                                                         ))
      end

      it 'returns pluralized count' do
        expect(component.send(:group_count_text)).to eq('3 updates')
      end

      context 'when helper raises error' do
        before do
          allow(component).to receive(:helpers).and_raise(StandardError.new('helper error'))
        end

        it 'falls back to simple format' do
          expect(component.send(:group_count_text)).to eq('3 updates')
        end
      end
    end
  end

  describe '#action_url' do
    let(:component) { described_class.new(notification: notification) }

    context 'when deeplink helper returns a path' do
      before do
        allow(component).to receive(:helpers).and_return(double(
                                                           notification_deeplink_path: '/notifications/open/123'
                                                         ))
      end

      it 'uses the deeplink helper' do
        expect(component.send(:action_url)).to eq('/notifications/open/123')
      end
    end

    context 'when deeplink is unavailable but notification responds to action_url' do
      before do
        allow(component).to receive(:helpers).and_return(double(
                                                           notification_deeplink_path: '#'
                                                         ))

        def notification.action_url
          '/custom/action/url'
        end
      end

      it 'returns notification action_url' do
        expect(component.send(:action_url)).to eq('/custom/action/url')
      end
    end

    context 'when notification does not respond to action_url' do
      before do
        allow(component).to receive(:helpers).and_return(double(
                                                           notification_deeplink_path: '#',
                                                           organisation_project_ticket_path: '/tickets/456'
                                                         ))
      end

      it 'generates URL based on notifiable type' do
        expect(component.send(:action_url)).to eq('/tickets/456')
      end

      context 'with Project notifiable' do
        let(:notification) { create(:notification, recipient: user, notifiable: project, organisation: organisation) }

        before do
          allow(component).to receive(:helpers).and_return(double(
                                                             notification_deeplink_path: '#',
                                                             organisation_project_path: '/projects/1'
                                                           ))
        end

        it 'generates project URL' do
          expect(component.send(:action_url)).to eq('/projects/1')
        end
      end

      context 'when helper raises error' do
        before do
          allow(component).to receive(:helpers).and_raise(StandardError.new('helper error'))
        end

        it 'returns nil' do
          expect(component.send(:action_url)).to be_nil
        end
      end
    end
  end

  describe '#mark_read_url' do
    let(:component) { described_class.new(notification: notification) }

    before do
      allow(component).to receive(:helpers).and_return(double(
                                                         mark_read_organisation_notification_path: '/notifications/123'
                                                       ))
    end

    it 'returns mark read URL' do
      expect(component.send(:mark_read_url)).to eq('/notifications/123')
    end

    context 'when helper raises error' do
      before do
        allow(component).to receive(:helpers).and_raise(StandardError.new('helper error'))
      end

      it 'falls back to #' do
        expect(component.send(:mark_read_url)).to eq('#')
      end
    end
  end

  describe '#notifiable_title' do
    let(:component) { described_class.new(notification: notification) }

    context 'when notifiable is present' do
      it 'returns ticket title' do
        expect(component.send(:notifiable_title)).to eq('Demo Ticket')
      end
    end

    context 'when notifiable is nil' do
      before do
        allow(notification).to receive(:notifiable).and_return(nil)
      end

      it 'returns System' do
        expect(component.send(:notifiable_title)).to eq('System')
      end
    end

    context 'when notifiable has name instead of title' do
      let(:notification) { create(:notification, recipient: user, notifiable: project, organisation: organisation) }

      it 'returns notifiable name' do
        expect(component.send(:notifiable_title)).to eq('Demo Project')
      end
    end

    context 'when notifiable has neither title nor name' do
      let(:custom_object) { double('CustomObject', class: double(name: 'CustomClass')) }

      before do
        allow(notification).to receive(:notifiable).and_return(custom_object)
        allow(custom_object).to receive(:try).with(:title).and_return(nil)
        allow(custom_object).to receive(:try).with(:name).and_return(nil)
      end

      it 'returns class name' do
        expect(component.send(:notifiable_title)).to eq('CustomClass')
      end
    end
  end

  describe '#priority_class' do
    let(:component) { described_class.new(notification: notification) }

    context 'when notification has high priority' do
      before { notification.update!(priority: 'high') }

      it 'returns high priority class' do
        expect(component.send(:priority_class)).to eq('notification-item--high-priority')
      end
    end

    context 'when notification has critical priority' do
      before { notification.update!(priority: 'critical') }

      it 'returns high priority class' do
        expect(component.send(:priority_class)).to eq('notification-item--high-priority')
      end
    end

    context 'when notification has normal priority' do
      it 'returns empty string' do
        expect(component.send(:priority_class)).to eq('')
      end
    end
  end

  describe 'helper methods' do
    let(:component) { described_class.new(notification: notification) }

    describe '#fallback_message' do
      it 'returns simple fallback message' do
        expect(component.send(:fallback_message)).to eq('Ticket commented notification')
      end
    end

    describe '#actor_display_name' do
      it 'returns the actor name in the viewer mode (full without a viewer)' do
        render_inline(component)

        expect(component.send(:actor_display_name)).to eq('Jane Smith')
      end

      context 'when actor is nil' do
        before { notification.update!(actor: nil) }

        it 'returns System' do
          expect(component.send(:actor_display_name)).to eq('System')
        end
      end
    end

    describe '#notifiable_display_name' do
      context 'with Ticket' do
        it 'returns ticket number and title' do
          expect(component.send(:notifiable_display_name)).to eq('#456 Demo Ticket')
        end
      end

      context 'with Project' do
        let(:notification) { create(:notification, recipient: user, notifiable: project, organisation: organisation) }

        it 'returns project name' do
          expect(component.send(:notifiable_display_name)).to eq('Demo Project')
        end
      end

      context 'with Document' do
        let(:document) do
          doc = create(:document, project: project, organisation: organisation)
          version = build(:document_version, document: doc, organisation: organisation, title: 'Demo Document')
          # Assign without triggering validations/callbacks
          doc.current_version = version
          doc
        end
        let(:notification) { create(:notification, recipient: user, notifiable: document, organisation: organisation) }

        it 'returns document name' do
          expect(component.send(:notifiable_display_name)).to eq('Demo Document')
        end
      end

      context 'with unknown type' do
        let(:custom_object) { double('CustomObject', class: double(name: 'CustomClass')) }

        before do
          allow(notification).to receive(:notifiable).and_return(custom_object)
          allow(custom_object).to receive(:try).with(:title).and_return(nil)
          allow(custom_object).to receive(:try).with(:name).and_return('Custom Name')
        end

        it 'returns custom name' do
          expect(component.send(:notifiable_display_name)).to eq('Custom Name')
        end
      end
    end
  end

  describe 'variant handling' do
    context 'with compact variant' do
      subject { render_inline(described_class.new(notification: notification, variant: :compact)) }

      it 'renders without errors' do
        expect(subject.to_html).to be_present
      end
    end

    context 'with custom variant' do
      subject { render_inline(described_class.new(notification: notification, variant: :custom)) }

      it 'renders without errors' do
        expect(subject.to_html).to be_present
      end
    end
  end

  describe 'configuration options' do
    context 'when show_avatar is false' do
      let(:component) { described_class.new(notification: notification, show_avatar: false) }

      it 'sets show_avatar to false' do
        expect(component.show_avatar).to be false
      end
    end

    context 'when show_actions is false' do
      let(:component) { described_class.new(notification: notification, show_actions: false) }

      it 'sets show_actions to false' do
        expect(component.show_actions).to be false
      end
    end

    context 'when clickable is false' do
      let(:component) { described_class.new(notification: notification, clickable: false) }

      it 'sets clickable to false' do
        expect(component.clickable).to be false
      end
    end
  end
end
