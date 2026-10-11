# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AdHocFilterHelper, type: :helper do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe '#ad_hoc_filter_categories_json' do
    context 'with select custom attributes' do
      before do
        create(:ticket_attribute_definition,
               project: project,
               name: 'status',
               field_type: 'select',
               system: true,
               position: 1,
               options: {
                 'allowed_values' => [
                   { 'value' => 'Offen', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
                   { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt', 'en' => 'Done' } }
                 ]
               })

        create(:ticket_attribute_definition,
               project: project,
               name: 'priority',
               field_type: 'select',
               position: 2,
               options: {
                 'allowed_values' => [
                   { 'value' => 'high', 'labels' => { 'de' => 'Hoch', 'en' => 'High' } },
                   { 'value' => 'low', 'labels' => { 'de' => 'Niedrig', 'en' => 'Low' } }
                 ]
               })
      end

      it 'includes all select custom attributes as categories' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        keys = result.map { |c| c['key'] }

        expect(keys).to include('status', 'priority')
      end

      it 'includes assignee and tag as special categories' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        keys = result.map { |c| c['key'] }

        expect(keys).to include('assignee', 'tag')
      end

      it 'places custom attributes before special categories' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        keys = result.map { |c| c['key'] }

        status_idx = keys.index('status')
        priority_idx = keys.index('priority')
        assignee_idx = keys.index('assignee')
        tag_idx = keys.index('tag')

        expect(status_idx).to be < assignee_idx
        expect(priority_idx).to be < assignee_idx
        expect(assignee_idx).to be < tag_idx
      end

      it 'sets correct type for custom attributes' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        status_cat = result.find { |c| c['key'] == 'status' }

        expect(status_cat['type']).to eq('custom_attribute')
      end

      it 'sets correct type for special categories' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        assignee_cat = result.find { |c| c['key'] == 'assignee' }

        expect(assignee_cat['type']).to eq('special')
      end

      it 'includes correct options with value and label' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        status_cat = result.find { |c| c['key'] == 'status' }

        expect(status_cat['options']).to be_an(Array)
        expect(status_cat['options'].length).to eq(2)
        expect(status_cat['options'].first).to include('value' => 'Offen')
        expect(status_cat['options'].first['label']).to be_present
      end

      it 'uses correct icons for known fields' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        status_cat = result.find { |c| c['key'] == 'status' }
        priority_cat = result.find { |c| c['key'] == 'priority' }

        expect(status_cat['icon']).to eq('bi-circle')
        expect(priority_cat['icon']).to eq('bi-flag')
      end
    end

    context 'with multiselect custom attributes' do
      before do
        create(:ticket_attribute_definition,
               project: project,
               name: 'skills',
               field_type: 'multiselect',
               position: 1,
               options: {
                 'allowed_values' => [
                   { 'value' => 'ruby', 'labels' => { 'de' => 'Ruby', 'en' => 'Ruby' } },
                   { 'value' => 'javascript', 'labels' => { 'de' => 'JavaScript', 'en' => 'JavaScript' } }
                 ]
               })
      end

      it 'includes multiselect attributes as categories' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        skills_cat = result.find { |c| c['key'] == 'skills' }

        expect(skills_cat).to be_present
        expect(skills_cat['type']).to eq('custom_attribute')
        expect(skills_cat['options'].length).to eq(2)
      end

      it 'uses default icon for unknown field names' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        skills_cat = result.find { |c| c['key'] == 'skills' }

        expect(skills_cat['icon']).to eq('bi-sliders')
      end
    end

    context 'with inactive custom attributes' do
      before do
        create(:ticket_attribute_definition,
               project: project,
               name: 'archived_field',
               field_type: 'select',
               active: false,
               options: {
                 'allowed_values' => [
                   { 'value' => 'a', 'labels' => { 'de' => 'A', 'en' => 'A' } }
                 ]
               })
      end

      it 'excludes inactive attributes' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        keys = result.map { |c| c['key'] }

        expect(keys).not_to include('archived_field')
      end
    end

    context 'with text/checkbox custom attributes' do
      before do
        create(:ticket_attribute_definition,
               project: project,
               name: 'description_field',
               field_type: 'text')

        create(:ticket_attribute_definition,
               project: project,
               name: 'is_urgent',
               field_type: 'checkbox')
      end

      it 'excludes non-select/multiselect attributes' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        keys = result.map { |c| c['key'] }

        expect(keys).not_to include('description_field', 'is_urgent')
      end
    end

    context 'with assignee options' do
      it 'includes users with access sorted by name' do
        user_b = create(:user, first_name: 'Alpha', last_name: 'User')
        create(:membership, user: user_b, organisation: organisation, role: admin_role, active: true)

        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        assignee_cat = result.find { |c| c['key'] == 'assignee' }

        expect(assignee_cat['options']).to be_an(Array)
        labels = assignee_cat['options'].map { |o| o['label'] }
        expect(labels).to eq(labels.sort_by(&:downcase))
      end
    end

    context 'with tag options' do
      before do
        ticket = create(:ticket, project: project, organisation: organisation, creator: user)
        tag = create(:tag, name: 'important', organisation: organisation)
        create(:tagging, tag: tag, taggable: ticket)
      end

      it 'includes tags used on project tickets' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        tag_cat = result.find { |c| c['key'] == 'tag' }

        expect(tag_cat['options']).to be_an(Array)
        expect(tag_cat['options'].first).to include('value' => 'important', 'label' => 'important')
      end
    end

    context 'without any tag on the project tickets' do
      it 'says why the tag menu is empty' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        tag_cat = result.find { |c| c['key'] == 'tag' }

        expect(tag_cat['options']).to eq([])
        expect(tag_cat['empty_hint']).to eq(I18n.t('views.organisations.tickets.index.no_tag_options'))
        expect(tag_cat['empty_hint']).not_to include('translation missing')
      end
    end

    context 'with creator category' do
      it 'includes creator with same users as assignee' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        creator_cat = result.find { |c| c['key'] == 'creator' }
        assignee_cat = result.find { |c| c['key'] == 'assignee' }

        expect(creator_cat).to be_present
        expect(creator_cat['type']).to eq('special')
        expect(creator_cat['icon']).to eq('bi-person-badge')
        expect(creator_cat['options']).to eq(assignee_cat['options'])
      end
    end

    context 'with date filter categories' do
      it 'includes created_at with date presets' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        created_cat = result.find { |c| c['key'] == 'created_at' }

        expect(created_cat).to be_present
        expect(created_cat['type']).to eq('special')
        expect(created_cat['icon']).to eq('bi-calendar-plus')
        preset_values = created_cat['options'].map { |o| o['value'] }
        expect(preset_values).to eq(%w[today yesterday last_7_days last_30_days this_week this_month])
      end

      it 'includes updated_at with date presets' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        updated_cat = result.find { |c| c['key'] == 'updated_at' }

        expect(updated_cat).to be_present
        expect(updated_cat['type']).to eq('special')
        expect(updated_cat['icon']).to eq('bi-calendar-check')
        preset_values = updated_cat['options'].map { |o| o['value'] }
        expect(preset_values).to eq(%w[today yesterday last_7_days last_30_days this_week this_month])
      end

      it 'has localized labels for date presets' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        created_cat = result.find { |c| c['key'] == 'created_at' }
        labels = created_cat['options'].map { |o| o['label'] }

        # All labels should be resolved (not raw keys)
        labels.each do |label|
          expect(label).not_to include('translation missing')
        end
      end
    end

    context 'with no custom attributes' do
      it 'still includes all special categories' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        keys = result.map { |c| c['key'] }

        expect(keys).to contain_exactly('assignee', 'creator', 'tag', 'created_at', 'updated_at', 'waiting', 'blocking')
      end
    end

    # The waiting states (doc/ticket_relations_plan.md, revision 4, §9): one option, the flag,
    # with "ist" and "ist nicht". The chip says "ja" or "nein" instead of "nicht <option>".
    context 'with the waiting states' do
      { 'waiting' => 'filter_waiting', 'blocking' => 'filter_blocking' }.each do |key, label_key|
        it "offers #{key} as a yes/no category in both locales" do
          # The same categories twice, once per locale, which Prosopite would read as N+1.
          Prosopite.pause do
            %i[de en].each do |locale|
              I18n.with_locale(locale) do
                category = JSON.parse(helper.ad_hoc_filter_categories_json(project)).find { |c| c['key'] == key }
                label = I18n.t("views.organisations.tickets.index.#{label_key}", raise: true)

                expect(category).to include('label' => label, 'type' => 'special', 'icon' => 'bi-hourglass-split',
                                            'allowed_operators' => %w[or not])
                expect(category['options']).to eq([{ 'value' => 'true', 'label' => label }])
                expect(category['flag_labels']).to eq(
                  'yes' => I18n.t('views.organisations.tickets.index.filter_flag_yes', raise: true),
                  'no' => I18n.t('views.organisations.tickets.index.filter_flag_no', raise: true)
                )
              end
            end
          end
        end
      end

      it 'stand after the other categories' do
        keys = JSON.parse(helper.ad_hoc_filter_categories_json(project)).map { |c| c['key'] }
        expect(keys.last(2)).to eq(%w[waiting blocking])
      end

      # Meetings build their categories in MeetingsHelper, which needs a policy scope; that the
      # filter service ignores the states on notes, documents and meetings holds
      # ad_hoc_filter_service_waiting_spec.rb.
      it 'are not offered on the knowledge list' do
        knowledge = JSON.parse(helper.knowledge_filter_categories_json(project, Knowledge::TypeRegistry.keys))

        keys = knowledge.map { |c| c['key'] }
        expect(keys).to include('tag')
        expect(keys).not_to include('waiting', 'blocking')
      end
    end

    # ── Operator tests (Phase 3) ──────────────────────────────────────

    context 'allowed_operators per category type' do
      before do
        create(:ticket_attribute_definition,
               project: project,
               name: 'status',
               field_type: 'select',
               system: true,
               position: 1,
               options: {
                 'allowed_values' => [
                   { 'value' => 'Offen', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } }
                 ]
               })

        create(:ticket_attribute_definition,
               project: project,
               name: 'skills',
               field_type: 'multiselect',
               position: 2,
               options: {
                 'allowed_values' => [
                   { 'value' => 'ruby', 'labels' => { 'de' => 'Ruby', 'en' => 'Ruby' } }
                 ]
               })
      end

      it 'returns [or, not] for select attributes' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        status_cat = result.find { |c| c['key'] == 'status' }

        expect(status_cat['allowed_operators']).to eq(%w[or not])
      end

      it 'returns [or, and, not] for multiselect attributes' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        skills_cat = result.find { |c| c['key'] == 'skills' }

        expect(skills_cat['allowed_operators']).to eq(%w[or and not])
      end

      it 'returns [or, and, not] for tag category' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        tag_cat = result.find { |c| c['key'] == 'tag' }

        expect(tag_cat['allowed_operators']).to eq(%w[or and not])
      end

      it 'returns [or, not] for assignee category' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        assignee_cat = result.find { |c| c['key'] == 'assignee' }

        expect(assignee_cat['allowed_operators']).to eq(%w[or not])
      end

      it 'returns [or, not] for creator category' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        creator_cat = result.find { |c| c['key'] == 'creator' }

        expect(creator_cat['allowed_operators']).to eq(%w[or not])
      end

      it 'returns [or, not] for created_at date category' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        created_cat = result.find { |c| c['key'] == 'created_at' }

        expect(created_cat['allowed_operators']).to eq(%w[or not])
      end

      it 'returns [or, not] for updated_at date category' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        updated_cat = result.find { |c| c['key'] == 'updated_at' }

        expect(updated_cat['allowed_operators']).to eq(%w[or not])
      end
    end

    context 'due_date category (conditional on a deadline field)' do
      it 'is OMITTED when the project has no deadline-marked date field' do
        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))

        expect(result.map { |c| c['key'] }).not_to include('due_date')
      end

      it 'is INCLUDED with the 4 presets when the project has a deadline date field' do
        create(:ticket_attribute_definition, project: project, name: 'due_date', field_type: 'date',
                                             labels: { 'de' => 'Fälligkeit', 'en' => 'Due date' }, options: { 'deadline' => true })

        result = JSON.parse(helper.ad_hoc_filter_categories_json(project))
        due_cat = result.find { |c| c['key'] == 'due_date' }

        expect(due_cat).to be_present
        expect(due_cat['type']).to eq('special')
        expect(due_cat['options'].map { |o| o['value'] }).to eq(Ticket::DUE_DATE_PRESET_KEYS)
      end
    end
  end
end
