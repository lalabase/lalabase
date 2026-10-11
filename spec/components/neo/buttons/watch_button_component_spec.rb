# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Neo::Buttons::WatchButtonComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, creator: create(:user)) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: ticket.creator, organisation: organisation, role: admin_role, active: true)
  end

  def render_component(**overrides)
    options = { item: ticket, user: user }.merge(overrides)
    component = described_class.new(**options)
    # Stub toggle_path to avoid route helper issues in component tests
    allow(component).to receive(:toggle_path).and_return('/test/toggle')
    render_inline(component)
  end

  describe 'watching state (follow subscription exists)' do
    before do
      NotificationSubscription.create!(user: user, subscribable: ticket, mode: 'follow')
    end

    it 'shows "Aktiv" text' do
      render_component
      expect(page).to have_content('Aktiv')
    end

    it 'uses bell icon' do
      render_component
      expect(page).to have_css('i.bi.bi-bell')
    end

    it 'uses primary variant' do
      component = described_class.new(item: ticket, user: user)
      expect(component.send(:button_variant)).to eq(:primary)
    end
  end

  describe 'not watching state (no subscription)' do
    it 'shows "Aus" text' do
      render_component
      expect(page).to have_content('Aus')
    end

    it 'uses bell-slash icon' do
      render_component
      expect(page).to have_css('i.bi.bi-bell-slash')
    end

    it 'uses ghost variant' do
      component = described_class.new(item: ticket, user: user)
      expect(component.send(:button_variant)).to eq(:ghost)
    end
  end

  describe 'override detection' do
    context 'when user is assignee but manually turned off (mute)' do
      before do
        create(:ticket_assignment, user: user, ticket: ticket)
        sub = NotificationSubscription.find_by(user: user, subscribable: ticket)
        sub.update!(mode: 'mute')
      end

      it 'shows "Manuell deaktiviert" override indicator' do
        render_component
        expect(page).to have_css("span[title='Manuell deaktiviert']")
      end
    end

    context 'when user has no auto-relation but manually follows' do
      before do
        NotificationSubscription.create!(user: user, subscribable: ticket, mode: 'follow')
      end

      it 'shows "Manuell aktiviert" override indicator' do
        render_component
        expect(page).to have_css("span[title='Manuell aktiviert']")
      end
    end

    context 'when state matches auto-rules (assignee + following)' do
      before do
        create(:ticket_assignment, user: user, ticket: ticket)
        # auto_subscribe_assignee creates follow subscription automatically
      end

      it 'does NOT show override text' do
        render_component
        expect(page).not_to have_content('Manuell')
      end
    end

    context 'when state matches auto-rules (no relation + not watching)' do
      it 'does NOT show override text' do
        render_component
        expect(page).not_to have_content('Manuell')
      end
    end
  end

  describe 'icon_only mode' do
    before do
      NotificationSubscription.create!(user: user, subscribable: ticket, mode: 'follow')
    end

    it 'does not show text' do
      render_component(icon_only: true)
      expect(page).not_to have_content('Aktiv')
      expect(page).not_to have_content('Aus')
    end

    it 'does not show override text even when override exists' do
      render_component(icon_only: true)
      expect(page).not_to have_content('Manuell')
    end
  end

  describe '#render?' do
    it 'renders when user can view the ticket' do
      component = described_class.new(item: ticket, user: user)
      expect(component.render?).to be true
    end

    it 'does not render when user cannot view the ticket' do
      outsider = create(:user)
      component = described_class.new(item: ticket, user: outsider)
      expect(component.render?).to be false
    end
  end
end
