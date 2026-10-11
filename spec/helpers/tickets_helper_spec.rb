# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TicketsHelper, :ci_guard, type: :helper do
  describe '#assignable_users_for' do
    let(:organisation) { create(:organisation) }
    let(:project_a) { create(:project, organisation: organisation) }
    let(:project_b) { create(:project, organisation: organisation) }

    let(:standard_role) { create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true) }
    let(:admin_role) { create(:admin_role, organisation: organisation) }

    def member_with(role, active: true)
      user = create(:user)
      create(:membership, user: user, organisation: organisation, role: role, active: active)
      user
    end

    # Set tenant BEFORE the let! hooks (let! creates a before-hook at its
    # declaration site; a later-declared before block would run too late).
    before { ActsAsTenant.current_tenant = organisation }
    after  { ActsAsTenant.current_tenant = nil }

    let!(:member_a)  { member_with(standard_role).tap { |u| create(:project_permission, user: u, project: project_a, tickets_access: 'read_only') } }
    let!(:member_b)  { member_with(standard_role).tap { |u| create(:project_permission, user: u, project: project_b, tickets_access: 'read_only') } }
    let!(:org_admin) { member_with(admin_role) }

    it 'includes members with access to the project' do
      expect(helper.assignable_users_for(project_a)).to include(member_a)
    end

    it 'excludes members who only have access to a different project (the leak)' do
      expect(helper.assignable_users_for(project_a)).not_to include(member_b)
    end

    it 'includes org admins (must stay assignable everywhere)' do
      expect(helper.assignable_users_for(project_a)).to include(org_admin)
    end

    it 'excludes inactive members even if they hold a project permission' do
      inactive = member_with(standard_role, active: false)
      create(:project_permission, user: inactive, project: project_a, tickets_access: 'read_only')

      expect(helper.assignable_users_for(project_a)).not_to include(inactive)
    end

    it 'keeps a currently-assigned out-of-scope user in the options (no silent drop on edit)' do
      ticket = create(:ticket, project: project_a, organisation: organisation, creator: member_a)
      ticket.assignees = [member_b] # member_b has NO access to A, but is already assigned

      result = helper.assignable_users_for(project_a, ticket)

      expect(result).to include(member_b)
      expect(result).to include(member_a) # regular scope is preserved
    end

    it 'does not trust assignee_ids of an unsaved ticket (no name leak via submitted params)' do
      # Security rationale for the persisted? condition: assignee_ids of a NON-saved
      # ticket come from user input (e.g. form re-render after a validation error) and
      # could contain arbitrary user IDs. Only saved (trustworthy) assignments
      # may extend the selection list — otherwise an attacker could inject foreign names.
      new_ticket = Ticket.new(project: project_a, organisation: organisation, assignee_ids: [member_b.id])

      result = helper.assignable_users_for(project_a, new_ticket)

      expect(result).not_to include(member_b)
      expect(result).to include(member_a) # regular scope is preserved
    end
  end

  describe 'due date + priority bars' do
    let(:organisation) { create(:organisation) }
    let(:project) { create(:project, organisation: organisation) }

    before do
      ActsAsTenant.current_tenant = organisation
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                           options: { 'allowed_values' => [
                                             { 'value' => 'open', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
                                             { 'value' => 'closed', 'labels' => { 'de' => 'Zu', 'en' => 'Closed' },
                                               'system_functions' => [SystemFunctions::Registry::IS_CLOSED] }
                                           ] })
      create(:ticket_attribute_definition, project: project, name: 'priority', field_type: 'select',
                                           options: { 'allowed_values' => [
                                             { 'value' => 'low', 'labels' => { 'de' => 'Niedrig', 'en' => 'Low' }, 'level' => 1, 'color' => '#93C5FD' },
                                             { 'value' => 'high', 'labels' => { 'de' => 'Hoch', 'en' => 'High' }, 'level' => 2, 'color' => '#F97316' }
                                           ] })
      create(:ticket_attribute_definition, project: project, name: 'due_date', field_type: 'date',
                                           labels: { 'de' => 'Fälligkeit', 'en' => 'Due date' })
    end

    after { ActsAsTenant.current_tenant = nil }

    def ticket(attrs)
      build(:ticket, project: project, organisation: organisation, custom_attributes: attrs)
    end

    describe '#ticket_due_badge' do
      it 'is nil without a due date' do
        expect(helper.ticket_due_badge(ticket('status' => 'open'))).to be_nil
      end

      it 'renders the overdue chip (calendar-x) for a past-due, open ticket' do
        html = helper.ticket_due_badge(ticket('due_date' => 1.day.ago.to_date.iso8601, 'status' => 'open'))

        expect(html).to include('bi-calendar-x')
      end

      it 'renders a neutral chip (calendar-event) for a future due date' do
        html = helper.ticket_due_badge(ticket('due_date' => 1.day.from_now.to_date.iso8601, 'status' => 'open'))

        expect(html).to include('bi-calendar-event')
        expect(html).not_to include('bi-calendar-x')
      end

      it 'is not overdue (neutral chip) when the ticket is closed' do
        html = helper.ticket_due_badge(ticket('due_date' => 1.day.ago.to_date.iso8601, 'status' => 'closed'))

        expect(html).to include('bi-calendar-event')
        expect(html).not_to include('bi-calendar-x')
      end
    end

    describe '#ticket_priority_bars' do
      it 'renders signal bars (svg/rect) for a leveled priority' do
        html = helper.ticket_priority_bars(ticket('priority' => 'high'))

        expect(html).to include('<svg').and(include('rect'))
      end

      it 'is nil for a missing priority' do
        expect(helper.ticket_priority_bars(ticket('status' => 'open'))).to be_nil
      end
    end
  end

  # ⚠️ Pinned because the LOOK is the point here, and a look no test names goes
  # back to a pill the next time somebody touches this helper. Until 07.09.2026
  # a configured value was a filled pill in the list while the detail's status
  # had read as a dot for longer - the same value, two forms, depending on
  # where you looked.
  describe '#render_custom_attribute_value with a configured colour' do
    let(:organisation) { create(:organisation) }
    let(:project) { create(:project, organisation: organisation) }
    let(:ticket) { create(:ticket, project: project) }

    before { ActsAsTenant.current_tenant = organisation }
    after  { ActsAsTenant.current_tenant = nil }

    def definition_with(colour_option)
      create(:ticket_attribute_definition,
             project: project, name: 'status', field_type: 'select',
             options: { 'allowed_values' => [colour_option] })
    end

    it 'carries a configured hex on a dot, and leaves the label a plain word' do
      definition_with('value' => 'doing', 'labels' => { 'de' => 'In Arbeit' }, 'color' => '#22c55e')
      ticket.set_custom_attribute('status', 'doing')

      html = helper.render_custom_attribute_value(ticket, 'status', 'doing')

      expect(html).to include('rounded-full')
      expect(html).to include('background-color: #22c55e')
      expect(html).to include('In Arbeit')
      # The old shape: the colour as a FILL behind the label.
      expect(html).not_to include('px-2 py-0.5')
      expect(html).not_to match(/background-color: #22c55e; color:/)
    end

    it 'takes the ladder colour of the system function for the dot, no fill and no text half' do
      definition_with('value' => 'doing', 'labels' => { 'de' => 'In Arbeit' },
                      'system_functions' => [SystemFunctions::Registry::IS_IN_PROGRESS])
      ticket.set_custom_attribute('status', 'doing')

      html = helper.render_custom_attribute_value(ticket, 'status', 'doing')

      expect(html).to include('bg-amber-500')
      expect(html).not_to include('bg-amber-100')
      # a text colour belongs to a label standing ON a fill; it no longer is.
      expect(html).not_to include('text-amber-900')
      expect(html).not_to include('border-stroke')
    end
  end

  # Stored XSS (security test 26.09.2026): a colour written past the validation (legacy
  # rows, update_column) must never reach a style attribute.
  describe 'option colours that are not a hex value' do
    let(:organisation) { create(:organisation) }
    let(:project) { create(:project, organisation: organisation) }
    let(:ticket) { create(:ticket, project: project) }
    let(:payload) { '#000"><img src=x onerror=alert(1)>' }

    before { ActsAsTenant.current_tenant = organisation }
    after  { ActsAsTenant.current_tenant = nil }

    def definition_with_color(color)
      definition = create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                                        options: { 'allowed_values' => [
                                                          { 'value' => 'doing', 'labels' => { 'de' => 'In Arbeit' } }
                                                        ] })
      options = definition.options.deep_dup
      options['allowed_values'].first['color'] = color
      definition.update_column(:options, options) # a legacy row: bypasses the model validation
      definition
    end

    describe '#status_badge_style' do
      it 'returns the inline style for a valid colour (proves the branch is reached)' do
        expect(helper.status_badge_style(definition_with_color('#3B82F6'), 'doing'))
          .to eq(style: 'background-color: #3B82F6; color: #FFFFFF')
      end

      it 'returns no style for a manipulated colour' do
        expect(helper.status_badge_style(definition_with_color(payload), 'doing')).not_to have_key(:style)
      end

      it 'falls through to the name-based colour instead of dropping the badge' do
        definition = create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                                          options: { 'allowed_values' => [
                                                            { 'value' => 'offen', 'labels' => { 'de' => 'Offen' } }
                                                          ] })
        options = definition.options.deep_dup
        options['allowed_values'].first['color'] = payload
        definition.update_column(:options, options)

        expect(helper.status_badge_style(definition, 'offen')[:class]).to include(TicketColorMap::STATUS_COLORS['offen'])
      end

      it 'returns no style for a CSS injection' do
        expect(helper.status_badge_style(definition_with_color('red; background-image:url(https://x)'), 'doing'))
          .not_to have_key(:style)
      end
    end

    describe '#ticket_priority_bars' do
      it 'fills the bars with the fallback, not with a manipulated colour' do
        definition = create(:ticket_attribute_definition, project: project, name: 'priority', field_type: 'select',
                                                          options: { 'allowed_values' => [
                                                            { 'value' => 'high', 'labels' => { 'de' => 'Hoch' }, 'level' => 1 }
                                                          ] })
        options = definition.options.deep_dup
        options['allowed_values'].first['color'] = 'url(https://evil.example/x)'
        definition.update_column(:options, options)
        ticket.set_custom_attribute('priority', 'high')

        html = helper.ticket_priority_bars(ticket)

        expect(html).to include(NeoPriorityBarsComponent::FILLED_FALLBACK_COLOR)
        expect(html).not_to include('evil.example')
      end
    end

    describe '#render_custom_attribute_value' do
      it 'keeps a valid colour on the dot (proves the branch is reached)' do
        definition_with_color('#3B82F6')
        ticket.set_custom_attribute('status', 'doing')

        expect(helper.render_custom_attribute_value(ticket, 'status', 'doing')).to include('background-color: #3B82F6')
      end

      it 'does not carry a manipulated colour into the dot' do
        definition_with_color('red; background-image:url(https://x)')
        ticket.set_custom_attribute('status', 'doing')

        html = helper.render_custom_attribute_value(ticket, 'status', 'doing')

        expect(html).to include('In Arbeit')
        expect(html).not_to include('background-image')
      end
    end
  end
end
