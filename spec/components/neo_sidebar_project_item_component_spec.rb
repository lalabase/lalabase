# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NeoSidebarProjectItemComponent, type: :component do
  let(:organisation) { create(:organisation, code_indexing_enabled: true) } # per-org beta feature on
  let(:user) { create(:user, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation, name: 'Test Project') }
  let(:other_project) { create(:project, organisation: organisation, name: 'Other Project') }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  # Builds a component instance with fully stubbed helpers so that the
  # pure visibility/access logic is testable WITHOUT HTML rendering.
  # area_access? is false by default -> tests selectively enable individual areas.
  def build_component(proj: project, current_project: nil, current_tab: '', pinned_sections: [], project_pinned: false)
    component = described_class.new(project: proj, current_project: current_project, current_tab: current_tab,
                                    pinned_sections: pinned_sections, project_pinned: project_pinned)

    policy_double = instance_double(ProjectPolicy)
    allow(policy_double).to receive(:area_access?).and_return(false)
    allow(policy_double).to receive(:view_activities?).and_return(false)

    helpers_double = double('helpers')
    allow(helpers_double).to receive(:policy).with(proj).and_return(policy_double)
    allow(helpers_double).to receive(:current_user).and_return(user)
    allow(user).to receive(:has_permission_in_organisation?).and_return(false)

    # Path-helper stubs
    allow(helpers_double).to receive(:organisation_project_path).and_return("/org/#{proj.organisation_id}/projects/#{proj.id}")
    allow(helpers_double).to receive(:organisation_project_chats_path).and_return("/org/#{proj.organisation_id}/projects/#{proj.id}/chats")
    allow(helpers_double).to receive(:organisation_project_tickets_path).and_return("/org/#{proj.organisation_id}/projects/#{proj.id}/tickets")
    allow(helpers_double).to receive(:organisation_project_knowledge_index_path).and_return("/org/#{proj.organisation_id}/projects/#{proj.id}/knowledge")
    allow(helpers_double).to receive(:organisation_project_project_permissions_path).and_return("/org/#{proj.organisation_id}/projects/#{proj.id}/permissions")
    allow(helpers_double).to receive(:edit_organisation_project_path).and_return("/org/#{proj.organisation_id}/projects/#{proj.id}/edit")
    allow(helpers_double).to receive(:organisation_project_activities_path).and_return("/org/#{proj.organisation_id}/projects/#{proj.id}/activities")

    allow(component).to receive(:helpers).and_return(helpers_double)

    [component, policy_double, helpers_double]
  end

  # Convenience: component with full access to all areas.
  def accessible_component(**opts)
    component, policy = build_component(**opts)
    allow(policy).to receive(:area_access?).and_return(true)
    component
  end

  describe '#current?' do
    it 'returns true when project matches current_project' do
      component, = build_component(current_project: project)
      expect(component.current?).to be true
    end

    it 'returns false when project differs from current_project' do
      component, = build_component(current_project: other_project)
      expect(component.current?).to be false
    end

    it 'returns false when current_project is nil' do
      component, = build_component(current_project: nil)
      expect(component.current?).to be false
    end
  end

  # render_items is the core: ALL reachable items in canonical order.
  # DELIBERATELY current-independent for the primary items -> you can jump
  # from anywhere into any project.
  describe '#render_items' do
    context 'non-current project with full access' do
      it 'includes Dashboard even when the project is not open (jump into any project)' do
        component = accessible_component(current_project: other_project)
        tabs = component.render_items.map { |i| i[:tab] }
        expect(tabs).to include('dashboard', 'tickets', 'knowledge', 'meetings')
        # No chats tab (projekt_chat_abbau) and no times tab: the project's own
        # times page is gone, the organisation list carries the project filter.
        expect(tabs).not_to include('chats', 'time_sessions')
      end

      it 'excludes the secondary MORE_ITEMS (members/settings/activities)' do
        component = accessible_component(current_project: other_project)
        tabs = component.render_items.map { |i| i[:tab] }
        expect(tabs).not_to include('members', 'settings', 'activities')
      end
    end

    context 'access filtering' do
      it 'omits unreachable nav items but keeps Dashboard (always reachable)' do
        component, policy = build_component(current_project: other_project)
        allow(policy).to receive(:area_access?).with(:tickets, :read).and_return(true)
        allow(policy).to receive(:area_access?).with(:tickets, :write).and_return(false)
        # all remaining areas stay false

        expect(component.render_items.map { |i| i[:tab] }).to eq(%w[dashboard tickets])
      end
    end

    context 'chats (per-org beta gate)' do
      it 'excludes chats when the user lacks chat permission' do
        component, policy = build_component(current_project: project)
        allow(policy).to receive(:area_access?).and_return(true)
        allow(policy).to receive(:area_access?).with(:chats, :read).and_return(false)
        allow(policy).to receive(:area_access?).with(:chats, :write).and_return(false)

        expect(component.render_items.map { |i| i[:tab] }).not_to include('chats')
      end

      # M10: chat is gated ABOVE the area permission by the per-org beta flag — full
      # chat permission must still be hidden when the org has the feature toggled off.
      it 'excludes chats when the org beta feature is off, even with full chat permission' do
        organisation.update!(code_indexing_enabled: false)
        component = accessible_component(current_project: project)

        expect(component.render_items.map { |i| i[:tab] }).not_to include('chats')
      end
    end

    # The :meetings gate is area_rw?(:meetings) == read || write. BOTH sides are
    # pinned below, so shrinking the gate to a single side (a tempting
    # "simplification") turns exactly one test red. The access enum never yields
    # write-without-read in real data, so the write-only branch is only reachable
    # with a stubbed policy — which is precisely what this unit level is for.
    context 'meetings (Gespräche) — read||write access gate' do
      it 'includes meetings with ONLY read access (read branch)' do
        component, policy = build_component(current_project: project)
        allow(policy).to receive(:area_access?).with(:meetings, :read).and_return(true)
        allow(policy).to receive(:area_access?).with(:meetings, :write).and_return(false)

        expect(component.render_items.map { |i| i[:tab] }).to include('meetings')
      end

      it 'includes meetings with ONLY write access (guards the write branch of ||)' do
        component, policy = build_component(current_project: project)
        allow(policy).to receive(:area_access?).with(:meetings, :read).and_return(false)
        allow(policy).to receive(:area_access?).with(:meetings, :write).and_return(true)

        expect(component.render_items.map { |i| i[:tab] }).to include('meetings')
      end

      it 'excludes meetings without any :meetings access' do
        component, = build_component(current_project: project)
        # every area defaults to false in build_component

        expect(component.render_items.map { |i| i[:tab] }).not_to include('meetings')
      end
    end

    context 'administrative items (hinter "Mehr")' do
      it 'sind NICHT Teil von render_items (sie liegen hinter dem "Mehr"-Aufklapper)' do
        component = accessible_component(current_project: project)
        tabs = component.render_items.map { |i| i[:tab] }
        expect(tabs).not_to include('members', 'settings', 'activities')
      end

      it 'werden ueber more_items bereitgestellt — current-UNABHAENGIG (auch bei nicht-aktuellem Projekt)' do
        component = accessible_component(current_project: other_project)
        expect(component.more_items.map { |i| i[:tab] }).to include('members')
        expect(component.has_more_items?).to be true
      end

      it 'enthaelt settings nur mit der change_project_properties-Permission' do
        component, = build_component(current_project: other_project)
        allow(user).to receive(:has_permission_in_organisation?)
          .with(project.organisation, 'projects', 'change_project_properties').and_return(true)
        expect(component.more_items.map { |i| i[:tab] }).to include('settings')
      end

      it 'enthaelt activities nur wenn view_activities? true ist' do
        component, policy = build_component(current_project: other_project)
        allow(policy).to receive(:view_activities?).and_return(true)
        expect(component.more_items.map { |i| i[:tab] }).to include('activities')
      end

      it 'has_more_items? ist false ohne administrative Berechtigung' do
        component, = build_component(current_project: project)
        expect(component.has_more_items?).to be false
      end
    end
  end

  # Visible even when collapsed: pinned sections + (only on the current project) the active tab.
  describe '#always_visible_tabs' do
    it 'is empty for a non-current project without pins' do
      expect(accessible_component(current_project: other_project).always_visible_tabs).to eq([])
    end

    it 'contains pinned sections (current-independent)' do
      component = accessible_component(current_project: other_project, pinned_sections: %w[tickets])
      expect(component.always_visible_tabs).to eq(['tickets'])
    end

    it 'adds the active tab for the CURRENT project' do
      component = accessible_component(current_project: project, current_tab: 'tickets')
      expect(component.always_visible_tabs).to include('tickets')
    end

    it 'does NOT add the active tab for a non-current project (kein Auto-Aufklappen beim Navigieren)' do
      component = accessible_component(current_project: other_project, current_tab: 'tickets')
      expect(component.always_visible_tabs).to eq([])
    end
  end

  describe '#extra? and #has_extras?' do
    it 'marks a non-pinned, non-active item as extra (hinter dem Chevron)' do
      component = accessible_component(current_project: other_project)
      expect(component.extra?(component.nav_item_for('dashboard'))).to be true
    end

    it 'does NOT mark a pinned section as extra' do
      component = accessible_component(current_project: other_project, pinned_sections: %w[tickets])
      expect(component.extra?(component.nav_item_for('tickets'))).to be false
    end

    it 'has_extras? is true when reachable items exist beyond pinned/active' do
      component = accessible_component(current_project: other_project, pinned_sections: %w[tickets])
      expect(component.has_extras?).to be true
    end
  end

  describe '#pinned_sections' do
    it 'filters out sections the user cannot reach' do
      component, policy = build_component(current_project: other_project, pinned_sections: %w[tickets])
      allow(policy).to receive(:area_access?).and_return(false)
      expect(component.pinned_sections).to eq([])
    end

    it 'keeps reachable pinned sections' do
      component = accessible_component(current_project: other_project, pinned_sections: %w[tickets])
      expect(component.pinned_sections).to eq(['tickets'])
    end

    # projekt_chat_abbau: a pin stored under 'chats' survives in the user's JSON and
    # must render NOTHING, because pinned_sections filters through NAV_ITEMS. That is
    # the whole reason PINNABLE_SECTIONS could shrink without a data migration.
    it 'drops a stored chats pin, because there is no chats tab to render' do
      component = accessible_component(current_project: other_project, pinned_sections: %w[chats], project_pinned: true)
      expect(component.pinned_sections).to be_empty
    end

    it 'drops a pinned chats section when the user has no chat access' do
      component, policy = build_component(current_project: other_project, pinned_sections: %w[chats], project_pinned: true)
      allow(policy).to receive(:area_access?).and_return(true)
      allow(policy).to receive(:area_access?).with(:chats, :read).and_return(false)
      allow(policy).to receive(:area_access?).with(:chats, :write).and_return(false)
      expect(component.pinned_sections).to eq([])
    end

    it 'keeps a pinned meetings (Gespräche) section on a non-current project (current-independent)' do
      component = accessible_component(current_project: other_project, pinned_sections: %w[meetings])
      expect(component.pinned_sections).to eq(['meetings'])
    end

    it 'drops a pinned meetings section when the user has no :meetings access' do
      component, policy = build_component(current_project: other_project, pinned_sections: %w[meetings])
      allow(policy).to receive(:area_access?).and_return(true)
      allow(policy).to receive(:area_access?).with(:meetings, :read).and_return(false)
      allow(policy).to receive(:area_access?).with(:meetings, :write).and_return(false)
      expect(component.pinned_sections).to eq([])
    end
  end

  describe '#section_pinned? and #project_pinned?' do
    it 'reflects the passed-in state' do
      component = accessible_component(current_project: other_project, pinned_sections: %w[tickets], project_pinned: true)
      expect(component.project_pinned?).to be true
      expect(component.section_pinned?('tickets')).to be true
      expect(component.section_pinned?('knowledge')).to be false
    end
  end

  describe '#pinnable_section?' do
    it 'allows tickets, knowledge, documentation and meetings, but not chats or time_sessions' do
      component, = build_component
      expect(component.pinnable_section?('tickets')).to be true
      expect(component.pinnable_section?('knowledge')).to be true
      expect(component.pinnable_section?('documentation')).to be true
      expect(component.pinnable_section?('meetings')).to be true
      expect(component.pinnable_section?('time_sessions')).to be false
    end

    it 'rejects non-whitelisted sections' do
      component, = build_component
      expect(component.pinnable_section?('dashboard')).to be false
      expect(component.pinnable_section?('settings')).to be false
    end
  end

  describe '#nav_item_for' do
    it 'returns the NAV_ITEMS entry for a tab' do
      component, = build_component
      expect(component.nav_item_for('tickets')[:i18n]).to eq('navigation.tasks')
    end

    it 'returns nil for an unknown tab' do
      component, = build_component
      expect(component.nav_item_for('does_not_exist')).to be_nil
    end
  end

  describe '#project_dashboard_path' do
    it 'returns the project dashboard path (eine Quelle fuer Header-Link und Dashboard-Punkt)' do
      component, = build_component
      expect(component.project_dashboard_path).to eq("/org/#{project.organisation_id}/projects/#{project.id}")
    end
  end

  describe '#link_classes' do
    it 'returns active classes for the active tab on the current project' do
      component, = build_component(current_project: project, current_tab: 'tickets')
      expect(component.link_classes('tickets')).to include('sidebar-row--active')
    end

    it 'returns inactive classes for a non-active tab' do
      component, = build_component(current_project: project, current_tab: 'tickets')
      expect(component.link_classes('knowledge')).not_to include('sidebar-row--active')
    end

    it 'returns inactive classes for a non-current project' do
      component, = build_component(current_project: other_project, current_tab: 'tickets')
      expect(component.link_classes('tickets')).not_to include('sidebar-row--active')
    end

    # Meetings active state at the UNIT level: current_tab is injected as 'meetings',
    # so this exercises only active? (current? && current_tab == tab) -> link_classes.
    # The controller -> 'meetings' mapping (SidebarHelper#current_sidebar_tab) is proven
    # separately by the request spec's "active state on the meetings page".
    it 'marks meetings active on the current project when the meetings tab is selected' do
      component, = build_component(current_project: project, current_tab: 'meetings')
      expect(component.link_classes('meetings')).to include('sidebar-row--active')
    end

    # active? is `current? && current_tab == tab`: dropping the current? half would
    # light up meetings on EVERY project whenever the meetings tab is open. This
    # non-current case guards that conjunction.
    it 'keeps meetings inactive on a non-current project even when the meetings tab is selected' do
      component, = build_component(current_project: other_project, current_tab: 'meetings')
      expect(component.link_classes('meetings')).not_to include('sidebar-row--active')
    end
  end

  describe '#icon_classes' do
    # The icon no longer answers per tab: its colour follows the ROW's state
    # (components/sidebar_nav.css), so the same class is right in both cases and
    # the condition exists once instead of twice.
    it 'marks the icon as part of a sidebar row, whichever tab is active' do
      component, = build_component(current_project: project, current_tab: 'dashboard')

      expect(component.icon_classes('dashboard')).to include('sidebar-row__icon')
      expect(component.icon_classes('tickets')).to include('sidebar-row__icon')
    end
  end

  describe 'the look of a row' do
    # It is not this component's any more. Four constants here said what four
    # other places also said; since 07.09.2026 SidebarNavHelper owns it and the
    # stylesheet (components/sidebar_nav.css) says what the classes mean. What
    # this component still owns is WHICH row is active, so that is what is
    # pinned here - the marker, not the paint.
    it 'takes its classes from the one owner instead of carrying its own' do
      component, = build_component(current_project: project, current_tab: 'tickets')

      expect(component.link_classes('tickets')).to include('sidebar-row')
      expect(described_class.constants).not_to include(:ACTIVE_CLASSES, :INACTIVE_CLASSES)
    end
  end

  describe 'NAV_ITEMS' do
    it 'covers dashboard, tickets, knowledge, documentation, meetings in canonical order' do
      expect(described_class::NAV_ITEMS.map { |i| i[:tab] })
        .to eq(%w[dashboard tickets knowledge documentation meetings])
    end

    it 'routes Dashboard via project_dashboard_path (shared with the header link)' do
      dashboard = described_class::NAV_ITEMS.find { |i| i[:tab] == 'dashboard' }
      expect(dashboard[:path]).to eq(:project_dashboard_path)
    end

    # Locks the meetings entry as a contract: icon is the bi-chat-quote glyph
    # (design-review decision D8, the section's identity), the label reuses the
    # existing navigation.meetings key, and the row routes through meetings_path.
    # Any drift on these — a copy-pasted icon, a wrong i18n key, a mistyped path
    # symbol — turns this red.
    it 'wires the meetings entry to bi-chat-quote (D8), navigation.meetings and meetings_path' do
      meetings = described_class::NAV_ITEMS.find { |i| i[:tab] == 'meetings' }
      expect(meetings).to include(icon: 'bi-chat-quote', i18n: 'navigation.meetings', path: :meetings_path)
    end
  end

  describe 'MORE_ITEMS' do
    it 'contains members, settings, activities — each with a permission check' do
      expect(described_class::MORE_ITEMS.map { |i| i[:tab] }).to contain_exactly('members', 'settings', 'activities')
      expect(described_class::MORE_ITEMS.all? { |i| i[:perm].present? }).to be true
    end
  end
end
