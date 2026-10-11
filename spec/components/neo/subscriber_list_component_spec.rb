# frozen_string_literal: true

require 'rails_helper'

# The Slack-flat notified line (user mockup 05.09.2026): one text line naming
# the subscribers, and "aendern" swaps it for a checkbox editor IN PLACE.
# Component specs render WITHOUT a signed-in viewer, so two things hold here
# by construction: names fall back to the full spelling, and
# can_manage_others? is false (no policy user) - the add/remove rows and the
# search only appear in the request specs (tickets_name_display_spec).
RSpec.describe Neo::SubscriberListComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:current_user) { create(:user, first_name: 'Current', last_name: 'User') }
  let(:other_user) { create(:user, first_name: 'Other', last_name: 'Person') }
  let(:subscribed_by_user) { create(:user, first_name: 'Subscriber', last_name: 'Bot') }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, creator: current_user) }

  before do
    ActsAsTenant.current_tenant = organisation
    [current_user, other_user, subscribed_by_user].each do |u|
      create(:membership, user: u, organisation: organisation, role: admin_role, active: true)
    end
  end

  def render_component(open: false)
    render_inline(described_class.new(item: ticket, current_user: current_user, open: open))
  end

  describe 'the collapsed line' do
    it 'renders the container with correct DOM id and the label' do
      result = render_component
      expect(result.css("#subscriber_list_ticket_#{ticket.id}")).to be_present
      expect(result.text).to include(I18n.t('views.shared.subscriber_list.label'))
    end

    it 'names the viewer as own name plus (Du) marker, then the other subscribers' do
      NotificationSubscription.where(subscribable: ticket).destroy_all
      NotificationSubscription.system_subscribe(user: current_user, item: ticket, source: 'creator')
      NotificationSubscription.system_subscribe(user: other_user, item: ticket, source: 'assignee')

      result = render_component
      summary = result.at_css('[data-subscriber-picker-target="summary"]')
      expect(summary.text).to include("Current User (#{I18n.t('views.shared.subscriber_list.you')})")
      expect(summary.text).to include('Other Person')
      expect(summary.text).to include(I18n.t('views.shared.subscriber_list.change'))
    end

    it 'says nobody when there is no subscriber at all' do
      NotificationSubscription.where(subscribable: ticket).destroy_all

      result = render_component
      summary = result.at_css('[data-subscriber-picker-target="summary"]')
      expect(summary.text).to include(I18n.t('views.shared.subscriber_list.nobody'))
    end

    it 'starts collapsed and swaps server-side when open: is passed' do
      collapsed = render_component
      expect(collapsed.at_css('[data-subscriber-picker-target="summary"]')[:class]).not_to include('hidden')
      expect(collapsed.at_css('[data-subscriber-picker-target="editor"]')[:class]).to include('hidden')

      opened = render_component(open: true)
      expect(opened.at_css('[data-subscriber-picker-target="summary"]')[:class]).to include('hidden')
      expect(opened.at_css('[data-subscriber-picker-target="editor"]')[:class]).not_to include('hidden')
    end
  end

  describe 'the viewer row in the editor' do
    before { NotificationSubscription.where(subscribable: ticket).destroy_all }

    context 'when the viewer is following' do
      before do
        NotificationSubscription.system_subscribe(user: current_user, item: ticket, source: 'creator')
      end

      it 'shows a checked box, just "Du" and the source annotation' do
        # Next to the own chip, name plus (Du) marker were three labels for
        # one person (user correction 05.09.2026) - the collapsed text line
        # keeps "Current User (Du)", the row does not.
        result = render_component
        editor = result.at_css('[data-subscriber-picker-target="editor"]')
        row = editor.at_css('form button')
        expect(row.at_css('span.bg-cream-900 i.bi-check-lg')).to be_present
        expect(row.text).to include(I18n.t('views.shared.subscriber_list.you'))
        expect(row.text).not_to include('Current User')
        expect(row.text).to include(I18n.t('views.shared.subscriber_list.source_creator'))
        expect(row[:title]).to eq(I18n.t('views.shared.subscriber_list.toggle_mute'))
      end

      it 'keeps the editor open across the submit (subscriber_open rides along)' do
        result = render_component
        form = result.at_css('[data-subscriber-picker-target="editor"] form')
        expect(form.at_css('input[name="subscriber_open"]')).to be_present
      end
    end

    context 'when the viewer is muted' do
      before do
        NotificationSubscription.create!(user: current_user, subscribable: ticket, mode: 'mute')
      end

      it 'shows an unchecked box with the muted annotation' do
        result = render_component
        row = result.at_css('[data-subscriber-picker-target="editor"] form button')
        expect(row.at_css('span.bg-cream-900')).to be_nil
        expect(row.text).to include(I18n.t('views.shared.subscriber_list.muted_label'))
        expect(row[:title]).to eq(I18n.t('views.shared.subscriber_list.toggle_follow'))
      end
    end
  end

  describe 'other subscribers in the editor' do
    before { NotificationSubscription.where(subscribable: ticket).destroy_all }

    it 'renders a system subscription as a read-only row with its source annotation' do
      NotificationSubscription.system_subscribe(user: other_user, item: ticket, source: 'assignee')

      result = render_component
      editor = result.at_css('[data-subscriber-picker-target="editor"]')
      expect(editor.text).to include('Other Person')
      expect(editor.text).to include(I18n.t('views.shared.subscriber_list.source_assignee'))
      # No delete form for it - system subscriptions are managed by their own
      # lifecycle, and this spec has no policy user anyway.
      expect(editor.css('input[name="_method"][value="delete"]')).to be_empty
    end

    it 'does not show muted subscribers' do
      NotificationSubscription.create!(user: other_user, subscribable: ticket, mode: 'mute')

      result = render_component
      expect(result.text).not_to include('Other Person')
    end

    it 'offers no add rows and no search without a policy user' do
      result = render_component
      editor = result.at_css('[data-subscriber-picker-target="editor"]')
      expect(editor.css('input[name="user_id"]')).to be_empty
      expect(editor.text).not_to include(I18n.t('views.shared.subscriber_list.search_person'))
    end
  end

  # Who may be asked to follow: who may be assigned (Project#assignable_users).
  # The write refuses a deactivated member (NotificationSubscription
  # #validate_user_has_access), so the list must not offer one.
  describe 'the people offered to add' do
    it 'leaves a deactivated member out and keeps an active one' do
      NotificationSubscription.where(subscribable: ticket).destroy_all
      gone = create(:user, first_name: 'Gerda', last_name: 'Gegangen')
      create(:membership, user: gone, organisation: organisation, role: admin_role, active: false)

      offered = described_class.new(item: ticket, current_user: current_user).editor_inactive_entries.map { |entry| entry[:user] }

      expect(offered).to include(other_user)
      expect(offered).not_to include(gone)
    end
  end

  describe 'source labels' do
    let(:component) { described_class.new(item: ticket, current_user: current_user) }

    it 'returns correct labels for each source type' do
      sub_creator = NotificationSubscription.new(source: 'creator')
      sub_assignee = NotificationSubscription.new(source: 'assignee')
      sub_self = NotificationSubscription.new(source: 'self')
      sub_manual = NotificationSubscription.new(
        source: 'manual',
        subscribed_by: subscribed_by_user
      )
      sub_nil = NotificationSubscription.new(source: nil)

      render_inline(component)

      expect(component.source_label(sub_creator)).to eq(I18n.t('views.shared.subscriber_list.source_creator'))
      expect(component.source_label(sub_assignee)).to eq(I18n.t('views.shared.subscriber_list.source_assignee'))
      expect(component.source_label(sub_self)).to eq(I18n.t('views.shared.subscriber_list.source_self'))
      expect(component.source_label(sub_manual)).to include(subscribed_by_user.full_name)
      expect(component.source_label(sub_nil)).to eq(I18n.t('views.shared.subscriber_list.source_self'))
    end
  end
end
