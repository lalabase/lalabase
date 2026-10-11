# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AdHocFilterService do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user_a) { create(:user) }
  let(:user_b) { create(:user) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user_a, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: user_b, organisation: organisation, role: admin_role, active: true)

    # Create status attribute definition
    create(:ticket_attribute_definition,
           project: project,
           name: 'status',
           field_type: 'select',
           system: true,
           options: {
             'allowed_values' => [
               { 'value' => 'Offen', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
               { 'value' => 'In Bearbeitung', 'labels' => { 'de' => 'In Bearbeitung', 'en' => 'In Progress' } },
               { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt', 'en' => 'Done' } }
             ]
           })
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  let!(:ticket_open) do
    create(:ticket, project: project, organisation: organisation, creator: user_a,
                    custom_attributes: { 'status' => 'Offen' })
  end

  let!(:ticket_in_progress) do
    create(:ticket, project: project, organisation: organisation, creator: user_a,
                    custom_attributes: { 'status' => 'In Bearbeitung' })
  end

  let!(:ticket_done) do
    create(:ticket, project: project, organisation: organisation, creator: user_a,
                    custom_attributes: { 'status' => 'Erledigt' })
  end

  let(:base_query) { project.tickets }

  describe '#apply' do
    %w[participant occurred_at].each do |name|
      it "preserves ticket custom #{name} filters through saving and reloading" do
        create(:ticket_attribute_definition, project: project, name: name, field_type: 'select',
                                             options: { 'allowed_values' => [{ 'value' => 'today', 'labels' => { 'de' => 'Heute' } }] })
        ticket_open.update!(custom_attributes: ticket_open.custom_attributes.merge(name => 'today'))
        filters = { name => ['today'] }
        expect(described_class.new(project, filters).apply(base_query)).to contain_exactly(ticket_open)

        result = Actors::SaveSmartFolderFromFilters.call(project: project, current_user: user_a, name: 'Custom view',
                                                         filter_params: filters, operator_params: {}, target_object_type: 'Ticket')
        expect(result).to be_success
        folder = result.resource.reload
        expect(folder.smart_folder_rules.sole).to have_attributes(field: "custom_#{name}", operator: 'in_list', value: 'today')
        expect(SmartFolderQueryBuilder.new(folder, user_a).build_results_query).to contain_exactly(ticket_open)
      end
    end

    context 'with no filters' do
      it 'returns all tickets' do
        service = described_class.new(project, {})
        result = service.apply(base_query)
        expect(result.count).to eq(3)
      end
    end

    context 'with status filter (custom attribute)' do
      it 'filters by a single status' do
        service = described_class.new(project, { 'status' => ['Offen'] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open)
      end

      it 'filters by multiple statuses (OR)' do
        service = described_class.new(project, { 'status' => ['Offen', 'In Bearbeitung'] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_in_progress)
      end

      it 'returns nothing for non-existent status' do
        service = described_class.new(project, { 'status' => ['NonExistent'] })
        result = service.apply(base_query)
        expect(result).to be_empty
      end
    end

    context 'with custom attribute filter (priority)' do
      before do
        create(:ticket_attribute_definition,
               project: project,
               name: 'priority',
               field_type: 'select',
               options: {
                 'allowed_values' => [
                   { 'value' => 'high', 'labels' => { 'de' => 'Hoch', 'en' => 'High' } },
                   { 'value' => 'medium', 'labels' => { 'de' => 'Mittel', 'en' => 'Medium' } },
                   { 'value' => 'low', 'labels' => { 'de' => 'Niedrig', 'en' => 'Low' } }
                 ]
               })

        ticket_open.update!(custom_attributes: ticket_open.custom_attributes.merge('priority' => 'high'))
        ticket_in_progress.update!(custom_attributes: ticket_in_progress.custom_attributes.merge('priority' => 'medium'))
        ticket_done.update!(custom_attributes: ticket_done.custom_attributes.merge('priority' => 'low'))
      end

      it 'filters by a single priority' do
        service = described_class.new(project, { 'priority' => ['high'] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open)
      end

      it 'filters by multiple priorities (OR)' do
        service = described_class.new(project, { 'priority' => %w[high medium] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_in_progress)
      end

      it 'combines with status filter (AND)' do
        service = described_class.new(project, { 'status' => ['Offen'], 'priority' => ['high'] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open)
      end

      it 'returns nothing when AND yields no matches' do
        service = described_class.new(project, { 'status' => ['Erledigt'], 'priority' => ['high'] })
        result = service.apply(base_query)
        expect(result).to be_empty
      end
    end

    context 'with multiselect custom attribute' do
      before do
        create(:ticket_attribute_definition,
               project: project,
               name: 'skills',
               field_type: 'multiselect',
               options: {
                 'allowed_values' => [
                   { 'value' => 'ruby', 'labels' => { 'de' => 'Ruby', 'en' => 'Ruby' } },
                   { 'value' => 'javascript', 'labels' => { 'de' => 'JavaScript', 'en' => 'JavaScript' } },
                   { 'value' => 'python', 'labels' => { 'de' => 'Python', 'en' => 'Python' } }
                 ]
               })

        ticket_open.update!(custom_attributes: ticket_open.custom_attributes.merge('skills' => %w[ruby javascript]))
        ticket_in_progress.update!(custom_attributes: ticket_in_progress.custom_attributes.merge('skills' => %w[python]))
        ticket_done.update!(custom_attributes: ticket_done.custom_attributes.merge('skills' => %w[ruby python]))
      end

      it 'filters by a single skill (array containment)' do
        service = described_class.new(project, { 'skills' => ['ruby'] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_done)
      end

      it 'filters by multiple skills (OR)' do
        service = described_class.new(project, { 'skills' => %w[javascript python] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_in_progress, ticket_done)
      end

      it 'returns nothing for non-existent skill' do
        service = described_class.new(project, { 'skills' => ['go'] })
        result = service.apply(base_query)
        expect(result).to be_empty
      end
    end

    context 'with unknown attribute' do
      it 'applies JSONB filter without error (returns no matches)' do
        service = described_class.new(project, { 'nonexistent' => ['value'] })
        result = service.apply(base_query)
        expect(result).to be_empty
      end
    end

    context 'with assignee filter' do
      before do
        create(:ticket_assignment, ticket: ticket_open, user: user_a)
        create(:ticket_assignment, ticket: ticket_in_progress, user: user_b)
        create(:ticket_assignment, ticket: ticket_done, user: user_a)
        create(:ticket_assignment, ticket: ticket_done, user: user_b)
      end

      it 'filters by a single assignee' do
        service = described_class.new(project, { 'assignee' => [user_a.id] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_done)
      end

      it 'filters by multiple assignees (OR)' do
        service = described_class.new(project, { 'assignee' => [user_a.id, user_b.id] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_in_progress, ticket_done)
      end

      it 'returns only tickets with that assignee' do
        service = described_class.new(project, { 'assignee' => [user_b.id] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_in_progress, ticket_done)
      end
    end

    context 'with tag filter' do
      let(:tag_bug) { create(:tag, name: 'bug', organisation: organisation) }
      let(:tag_urgent) { create(:tag, name: 'urgent', organisation: organisation) }

      before do
        create(:tagging, tag: tag_bug, taggable: ticket_open)
        create(:tagging, tag: tag_urgent, taggable: ticket_open)
        create(:tagging, tag: tag_bug, taggable: ticket_in_progress)
      end

      it 'filters by a single tag' do
        service = described_class.new(project, { 'tag' => ['bug'] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_in_progress)
      end

      it 'filters by multiple tags (OR - any of)' do
        service = described_class.new(project, { 'tag' => %w[bug urgent] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_in_progress)
      end

      it 'returns nothing for non-existent tag' do
        service = described_class.new(project, { 'tag' => ['nonexistent'] })
        result = service.apply(base_query)
        expect(result).to be_empty
      end
    end

    context 'with creator filter' do
      it 'filters by a single creator' do
        service = described_class.new(project, { 'creator' => [user_a.id] })
        result = service.apply(base_query)
        # All 3 tickets were created by user_a
        expect(result).to contain_exactly(ticket_open, ticket_in_progress, ticket_done)
      end

      it 'returns nothing for creator with no tickets' do
        service = described_class.new(project, { 'creator' => [user_b.id] })
        result = service.apply(base_query)
        expect(result).to be_empty
      end

      it 'filters by multiple creators (OR)' do
        ticket_by_b = create(:ticket, project: project, organisation: organisation, creator: user_b,
                                      custom_attributes: { 'status' => 'Offen' })

        service = described_class.new(project, { 'creator' => [user_a.id, user_b.id] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_in_progress, ticket_done, ticket_by_b)
      end
    end

    context 'with created_at date filter' do
      let!(:old_ticket) do
        create(:ticket, project: project, organisation: organisation, creator: user_a,
                        custom_attributes: { 'status' => 'Offen' }).tap do |t|
          t.update_column(:created_at, 60.days.ago)
        end
      end

      it 'filters by last_7_days preset' do
        service = described_class.new(project, { 'created_at' => ['last_7_days'] })
        result = service.apply(base_query)
        # ticket_open, ticket_in_progress, ticket_done were created today, old_ticket 60 days ago
        expect(result).to contain_exactly(ticket_open, ticket_in_progress, ticket_done)
        expect(result).not_to include(old_ticket)
      end

      it 'filters by today preset' do
        service = described_class.new(project, { 'created_at' => ['today'] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_in_progress, ticket_done)
        expect(result).not_to include(old_ticket)
      end

      it 'filters by last_30_days (excludes 60-day-old ticket)' do
        service = described_class.new(project, { 'created_at' => ['last_30_days'] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_in_progress, ticket_done)
        expect(result).not_to include(old_ticket)
      end

      it 'ignores unknown preset values' do
        service = described_class.new(project, { 'created_at' => ['unknown_preset'] })
        result = service.apply(base_query)
        # Unknown preset is skipped, no date filter applied → returns all
        expect(result.count).to eq(4)
      end
    end

    context 'with updated_at date filter' do
      before do
        ticket_done.update_column(:updated_at, 60.days.ago)
      end

      it 'filters by last_7_days preset on updated_at' do
        service = described_class.new(project, { 'updated_at' => ['last_7_days'] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_in_progress)
        expect(result).not_to include(ticket_done)
      end
    end

    # ── Operator tests (Phase 3) ──────────────────────────────────────

    context 'with NOT operator on status (select)' do
      it 'excludes tickets matching the selected status' do
        service = described_class.new(project, { 'status' => ['Erledigt'] }, { 'status' => 'not' })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_in_progress)
      end

      it 'excludes multiple statuses' do
        service = described_class.new(project, { 'status' => ['Offen', 'In Bearbeitung'] }, { 'status' => 'not' })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_done)
      end

      it 'includes tickets without the attribute set (NULL handling)' do
        ticket_no_status = create(:ticket, project: project, organisation: organisation, creator: user_a,
                                           custom_attributes: {})
        service = described_class.new(project, { 'status' => ['Erledigt'] }, { 'status' => 'not' })
        result = service.apply(base_query)
        expect(result).to include(ticket_no_status)
      end
    end

    context 'with NOT operator on assignee' do
      before do
        create(:ticket_assignment, ticket: ticket_open, user: user_a)
        create(:ticket_assignment, ticket: ticket_in_progress, user: user_b)
        create(:ticket_assignment, ticket: ticket_done, user: user_a)
      end

      it 'excludes tickets assigned to the selected user' do
        service = described_class.new(project, { 'assignee' => [user_a.id] }, { 'assignee' => 'not' })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_in_progress)
      end
    end

    context 'with NOT operator on creator' do
      it 'excludes tickets created by the selected user' do
        ticket_by_b = create(:ticket, project: project, organisation: organisation, creator: user_b,
                                      custom_attributes: { 'status' => 'Offen' })
        service = described_class.new(project, { 'creator' => [user_a.id] }, { 'creator' => 'not' })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_by_b)
      end
    end

    context 'with NOT operator on tags' do
      let(:tag_bug) { create(:tag, name: 'bug', organisation: organisation) }
      let(:tag_urgent) { create(:tag, name: 'urgent', organisation: organisation) }

      before do
        create(:tagging, tag: tag_bug, taggable: ticket_open)
        create(:tagging, tag: tag_urgent, taggable: ticket_open)
        create(:tagging, tag: tag_bug, taggable: ticket_in_progress)
      end

      it 'excludes tickets with the selected tag' do
        service = described_class.new(project, { 'tag' => ['bug'] }, { 'tag' => 'not' })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_done)
      end

      it 'excludes tickets with any of the selected tags' do
        service = described_class.new(project, { 'tag' => %w[bug urgent] }, { 'tag' => 'not' })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_done)
      end
    end

    context 'with NOT operator on date' do
      let!(:old_ticket) do
        create(:ticket, project: project, organisation: organisation, creator: user_a,
                        custom_attributes: { 'status' => 'Offen' }).tap do |t|
          t.update_column(:created_at, 60.days.ago)
        end
      end

      it 'excludes tickets matching the date preset' do
        service = described_class.new(project, { 'created_at' => ['today'] }, { 'created_at' => 'not' })
        result = service.apply(base_query)
        expect(result).to contain_exactly(old_ticket)
      end
    end

    context 'with AND operator on tags' do
      let(:tag_bug) { create(:tag, name: 'bug', organisation: organisation) }
      let(:tag_urgent) { create(:tag, name: 'urgent', organisation: organisation) }

      before do
        create(:tagging, tag: tag_bug, taggable: ticket_open)
        create(:tagging, tag: tag_urgent, taggable: ticket_open)
        create(:tagging, tag: tag_bug, taggable: ticket_in_progress)
      end

      it 'returns only tickets with ALL selected tags' do
        service = described_class.new(project, { 'tag' => %w[bug urgent] }, { 'tag' => 'and' })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open)
      end

      it 'returns nothing when no ticket has all tags' do
        create(:tag, name: 'feature', organisation: organisation)
        service = described_class.new(project, { 'tag' => %w[bug feature] }, { 'tag' => 'and' })
        result = service.apply(base_query)
        expect(result).to be_empty
      end
    end

    context 'with AND operator on multiselect custom attribute' do
      before do
        create(:ticket_attribute_definition,
               project: project,
               name: 'skills',
               field_type: 'multiselect',
               options: {
                 'allowed_values' => [
                   { 'value' => 'ruby', 'labels' => { 'de' => 'Ruby', 'en' => 'Ruby' } },
                   { 'value' => 'javascript', 'labels' => { 'de' => 'JavaScript', 'en' => 'JavaScript' } },
                   { 'value' => 'python', 'labels' => { 'de' => 'Python', 'en' => 'Python' } }
                 ]
               })

        ticket_open.update!(custom_attributes: ticket_open.custom_attributes.merge('skills' => %w[ruby javascript]))
        ticket_in_progress.update!(custom_attributes: ticket_in_progress.custom_attributes.merge('skills' => %w[python]))
        ticket_done.update!(custom_attributes: ticket_done.custom_attributes.merge('skills' => %w[ruby python]))
      end

      it 'returns only tickets with ALL selected skills' do
        service = described_class.new(project, { 'skills' => %w[ruby javascript] }, { 'skills' => 'and' })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open)
      end

      it 'returns nothing when no ticket has all skills' do
        service = described_class.new(project, { 'skills' => %w[javascript python] }, { 'skills' => 'and' })
        result = service.apply(base_query)
        expect(result).to be_empty
      end
    end

    context 'with NOT operator on multiselect custom attribute' do
      before do
        create(:ticket_attribute_definition,
               project: project,
               name: 'skills',
               field_type: 'multiselect',
               options: {
                 'allowed_values' => [
                   { 'value' => 'ruby', 'labels' => { 'de' => 'Ruby', 'en' => 'Ruby' } },
                   { 'value' => 'javascript', 'labels' => { 'de' => 'JavaScript', 'en' => 'JavaScript' } },
                   { 'value' => 'python', 'labels' => { 'de' => 'Python', 'en' => 'Python' } }
                 ]
               })

        ticket_open.update!(custom_attributes: ticket_open.custom_attributes.merge('skills' => %w[ruby javascript]))
        ticket_in_progress.update!(custom_attributes: ticket_in_progress.custom_attributes.merge('skills' => %w[python]))
        ticket_done.update!(custom_attributes: ticket_done.custom_attributes.merge('skills' => %w[ruby python]))
      end

      it 'excludes tickets with any of the selected skills' do
        service = described_class.new(project, { 'skills' => ['ruby'] }, { 'skills' => 'not' })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_in_progress)
      end
    end

    context 'backward compatibility (no operator_params)' do
      it 'defaults to OR when operator_params is nil' do
        service = described_class.new(project, { 'status' => ['Offen', 'In Bearbeitung'] })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_in_progress)
      end

      it 'defaults to OR when operator_params is empty' do
        service = described_class.new(project, { 'status' => ['Offen', 'In Bearbeitung'] }, {})
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_in_progress)
      end
    end

    context 'invalid operator fallback' do
      it 'falls back to OR for unknown operator value' do
        service = described_class.new(project, { 'status' => ['Offen', 'In Bearbeitung'] }, { 'status' => 'invalid' })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open, ticket_in_progress)
      end
    end

    context 'combined operators across categories' do
      before do
        create(:ticket_assignment, ticket: ticket_open, user: user_a)
        create(:ticket_assignment, ticket: ticket_in_progress, user: user_a)
        create(:ticket_assignment, ticket: ticket_done, user: user_b)
      end

      it 'applies NOT on status AND OR on assignee (cross-category AND)' do
        service = described_class.new(
          project,
          { 'status' => ['Erledigt'], 'assignee' => [user_a.id] },
          { 'status' => 'not' }
        )
        result = service.apply(base_query)
        # NOT Erledigt → Offen + In Bearbeitung; AND assignee=user_a → Offen + In Bearbeitung
        expect(result).to contain_exactly(ticket_open, ticket_in_progress)
      end

      it 'applies NOT on status AND NOT on assignee' do
        service = described_class.new(
          project,
          { 'status' => ['Erledigt'], 'assignee' => [user_b.id] },
          { 'status' => 'not', 'assignee' => 'not' }
        )
        result = service.apply(base_query)
        # NOT Erledigt → Offen + In Bearbeitung
        # NOT user_b → Offen + In Bearbeitung (user_b only assigned to ticket_done)
        # Intersection → Offen + In Bearbeitung
        expect(result).to contain_exactly(ticket_open, ticket_in_progress)
      end
    end

    context 'with combined filters (AND)' do
      before do
        create(:ticket_assignment, ticket: ticket_open, user: user_a)
        create(:ticket_assignment, ticket: ticket_in_progress, user: user_a)
        create(:ticket_assignment, ticket: ticket_done, user: user_b)
      end

      it 'applies AND between status and assignee' do
        service = described_class.new(project, {
                                        'status' => ['Offen'],
                                        'assignee' => [user_a.id]
                                      })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open)
      end

      it 'returns nothing when AND yields no matches' do
        service = described_class.new(project, {
                                        'status' => ['Offen'],
                                        'assignee' => [user_b.id]
                                      })
        result = service.apply(base_query)
        expect(result).to be_empty
      end

      it 'combines creator with status (AND)' do
        service = described_class.new(project, {
                                        'status' => ['Offen'],
                                        'creator' => [user_a.id]
                                      })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open)
      end

      it 'combines date filter with status (AND)' do
        service = described_class.new(project, {
                                        'status' => ['Offen'],
                                        'created_at' => ['today']
                                      })
        result = service.apply(base_query)
        expect(result).to contain_exactly(ticket_open)
      end
    end
  end

  describe '#active?' do
    it 'returns false for empty filters' do
      service = described_class.new(project, {})
      expect(service.active?).to be false
    end

    it 'returns true when filters are present' do
      service = described_class.new(project, { 'status' => ['Offen'] })
      expect(service.active?).to be true
    end

    it 'returns false for filters with empty arrays' do
      service = described_class.new(project, { 'status' => [''] })
      expect(service.active?).to be false
    end
  end

  describe '#active_filters_metadata' do
    it 'returns metadata for status filter with labels' do
      service = described_class.new(project, { 'status' => ['Offen'] })
      metadata = service.active_filters_metadata

      expect(metadata['status']).to be_an(Array)
      expect(metadata['status'].first[:value]).to eq('Offen')
      expect(metadata['status'].first[:label]).to be_present
    end

    it 'returns metadata for assignee filter with display names' do
      service = described_class.new(project, { 'assignee' => [user_a.id] })
      metadata = service.active_filters_metadata

      expect(metadata['assignee']).to be_an(Array)
      expect(metadata['assignee'].first[:value]).to eq(user_a.id)
      expect(metadata['assignee'].first[:label]).to eq(user_a.display_name)
    end

    it 'returns metadata for tag filter' do
      service = described_class.new(project, { 'tag' => ['bug'] })
      metadata = service.active_filters_metadata

      expect(metadata['tag']).to be_an(Array)
      expect(metadata['tag'].first[:value]).to eq('bug')
      expect(metadata['tag'].first[:label]).to eq('bug')
    end

    it 'returns metadata for custom attribute with localized labels' do
      create(:ticket_attribute_definition,
             project: project,
             name: 'priority',
             field_type: 'select',
             options: {
               'allowed_values' => [
                 { 'value' => 'high', 'labels' => { 'de' => 'Hoch', 'en' => 'High' } }
               ]
             })

      service = described_class.new(project, { 'priority' => ['high'] })
      metadata = service.active_filters_metadata

      expect(metadata['priority']).to be_an(Array)
      expect(metadata['priority'].first[:value]).to eq('high')
      expect(metadata['priority'].first[:label]).to be_present
    end

    it 'returns metadata for creator filter with display names' do
      service = described_class.new(project, { 'creator' => [user_a.id] })
      metadata = service.active_filters_metadata

      expect(metadata['creator']).to be_an(Array)
      expect(metadata['creator'].first[:value]).to eq(user_a.id)
      expect(metadata['creator'].first[:label]).to eq(user_a.display_name)
    end

    it 'returns metadata for date filter with i18n labels' do
      service = described_class.new(project, { 'created_at' => ['last_7_days'] })
      metadata = service.active_filters_metadata

      expect(metadata['created_at']).to be_an(Array)
      expect(metadata['created_at'].first[:value]).to eq('last_7_days')
      expect(metadata['created_at'].first[:label]).to be_present
    end

    it 'returns empty hash for no filters' do
      service = described_class.new(project, {})
      expect(service.active_filters_metadata).to eq({})
    end
  end

  describe 'due-date quick-filter presets' do
    let(:dd_project) { create(:project, organisation: organisation) }

    before do
      create(:ticket_attribute_definition, project: dd_project, name: 'status', field_type: 'select',
                                           options: { 'allowed_values' => [
                                             { 'value' => 'open', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
                                             { 'value' => 'closed', 'labels' => { 'de' => 'Zu', 'en' => 'Closed' },
                                               'system_functions' => [SystemFunctions::Registry::IS_CLOSED] }
                                           ] })
      create(:ticket_attribute_definition, project: dd_project, name: 'due_date', field_type: 'date',
                                           labels: { 'de' => 'Fälligkeit', 'en' => 'Due date' }, options: { 'deadline' => true })
    end

    def dd_ticket(due:, status: 'open')
      create(:ticket, project: dd_project, organisation: organisation, creator: user_a,
                      custom_attributes: { 'due_date' => due, 'status' => status })
    end

    let!(:overdue_open)   { dd_ticket(due: 3.days.ago.to_date.iso8601) }
    let!(:overdue_closed) { dd_ticket(due: 3.days.ago.to_date.iso8601, status: 'closed') }
    let!(:due_today)      { dd_ticket(due: Date.current.iso8601) }
    let!(:due_in_5)       { dd_ticket(due: (Date.current + 5).iso8601) }
    let!(:due_in_20)      { dd_ticket(due: (Date.current + 20).iso8601) }

    def ids_for(presets)
      described_class.new(dd_project, { 'due_date' => Array(presets) }).apply(dd_project.tickets).pluck(:id)
    end

    it '`overdue` returns past-due, not-closed tickets only' do
      expect(ids_for('overdue')).to contain_exactly(overdue_open.id)
    end

    it '`due_today` returns tickets due today' do
      expect(ids_for('due_today')).to contain_exactly(due_today.id)
    end

    it '`due_next_7_days` returns due dates from today through +7 days' do
      expect(ids_for('due_next_7_days')).to contain_exactly(due_today.id, due_in_5.id)
    end

    it 'combines multiple presets as OR (overdue + due_today)' do
      expect(ids_for(%w[overdue due_today])).to contain_exactly(overdue_open.id, due_today.id)
    end

    it 'inverts the match with the `not` operator (NOT overdue → everything except overdue)' do
      ids = described_class.new(dd_project, { 'due_date' => ['overdue'] }, { 'due_date' => 'not' })
                           .apply(dd_project.tickets).pluck(:id)

      expect(ids).to contain_exactly(overdue_closed.id, due_today.id, due_in_5.id, due_in_20.id)
    end

    it 'inverts a multi-preset match as a group: NOT (overdue OR due_today)' do
      # Pins the parenthesised `NOT (#{or_clause})` — both selected presets are excluded together,
      # not just the last one.
      ids = described_class.new(dd_project, { 'due_date' => %w[overdue due_today] }, { 'due_date' => 'not' })
                           .apply(dd_project.tickets).pluck(:id)

      expect(ids).to contain_exactly(overdue_closed.id, due_in_5.id, due_in_20.id)
    end

    it 'drops a forged/unknown preset via the whitelist and applies NO filter (never crashes)' do
      # Kills a mutation that removes the `& Ticket::DUE_DATE_PRESET_KEYS` intersection — a forged
      # preset would otherwise reach matching_due_preset('bogus') and crash on due_within(*nil).
      all_ids = dd_project.tickets.pluck(:id)
      expect(ids_for('definitely_not_a_preset')).to match_array(all_ids)
    end
  end
end
