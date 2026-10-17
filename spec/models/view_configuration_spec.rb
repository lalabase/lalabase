# frozen_string_literal: true

# == Schema Information
#
# Table name: view_configurations
#
#  id                             :uuid             not null, primary key
#  detail_settings                :jsonb
#  header_columns                 :jsonb
#  list_columns                   :jsonb
#  pinned_columns                 :jsonb
#  table_columns                  :jsonb
#  view_mode                      :string           default("table")
#  view_type                      :string           default("tickets")
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#  kanban_attribute_definition_id :uuid
#  organisation_id                :uuid             not null
#  project_id                     :uuid
#  user_id                        :uuid             not null
#
# Indexes
#
#  index_view_configs_on_user_organisation_type_without_project  (user_id,organisation_id,view_type) UNIQUE WHERE (project_id IS NULL)
#  index_view_configs_on_user_project_type                       (user_id,project_id,view_type) UNIQUE
#  index_view_configurations_on_header_columns                   (header_columns) USING gin
#  index_view_configurations_on_list_columns                     (list_columns) USING gin
#  index_view_configurations_on_organisation_id                  (organisation_id)
#  index_view_configurations_on_project_id                       (project_id)
#  index_view_configurations_on_table_columns                    (table_columns) USING gin
#  index_view_configurations_on_user_id                          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (kanban_attribute_definition_id => ticket_attribute_definitions.id) ON DELETE => nullify
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
require 'rails_helper'

RSpec.describe ViewConfiguration do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
  end

  def build_config(**overrides)
    build(:view_configuration, organisation: organisation, user: user, project: project, **overrides)
  end

  # ──────────────────────────────────────────────
  # Validations
  # ──────────────────────────────────────────────

  describe 'validations' do
    describe 'view_type' do
      it 'requires presence' do
        config = build_config(view_type: nil)
        expect(config).not_to be_valid
        expect(config.errors[:view_type]).to be_present
      end

      %w[tickets notes documents].each do |valid_type|
        it "accepts '#{valid_type}'" do
          config = build_config(view_type: valid_type)
          expect(config).to be_valid
        end
      end

      it 'rejects unknown view_type' do
        config = build_config(view_type: 'kanban_board')
        expect(config).not_to be_valid
      end

      it 'rejects empty string' do
        config = build_config(view_type: '')
        expect(config).not_to be_valid
      end
    end

    describe 'uniqueness of user_id scoped to project + view_type' do
      it 'allows same user in different projects' do
        create(:view_configuration, organisation: organisation, user: user, project: project, view_type: 'tickets')
        other_project = create(:project, organisation: organisation)
        config = build_config(project: other_project, view_type: 'tickets')
        expect(config).to be_valid
      end

      it 'allows same user+project with different view_type' do
        create(:view_configuration, organisation: organisation, user: user, project: project, view_type: 'tickets')
        config = build_config(view_type: 'notes')
        expect(config).to be_valid
      end

      it 'rejects duplicate user+project+view_type' do
        create(:view_configuration, organisation: organisation, user: user, project: project, view_type: 'tickets')
        config = build_config(view_type: 'tickets')
        expect(config).not_to be_valid
        expect(config.errors[:user_id]).to be_present
      end
    end

    describe 'view_mode' do
      it 'allows nil' do
        config = build_config(view_mode: nil)
        expect(config).to be_valid
      end

      %w[table kanban].each do |mode|
        it "accepts '#{mode}'" do
          config = build_config(view_mode: mode)
          expect(config).to be_valid
        end
      end

      it 'rejects invalid mode' do
        config = build_config(view_mode: 'list')
        expect(config).not_to be_valid
      end
    end
  end

  # ──────────────────────────────────────────────
  # .for_user_project
  # ──────────────────────────────────────────────

  describe '.for_user_project' do
    it 'returns an existing record when one exists' do
      existing = create(:view_configuration, organisation: organisation, user: user, project: project, view_type: 'tickets')
      result = described_class.for_user_project(user, project, 'tickets')
      expect(result).to eq(existing)
      expect(result).to be_persisted
    end

    it 'initializes a new record with defaults when none exists' do
      result = described_class.for_user_project(user, project, 'tickets')
      expect(result).not_to be_persisted
      expect(result.table_columns).to eq(ViewConfiguration::DEFAULT_TABLE_COLUMNS)
      expect(result.list_columns).to be_blank
      expect(result.header_columns).to eq(ViewConfiguration::DEFAULT_HEADER_COLUMNS)
    end

    it 'defaults view_type to tickets' do
      result = described_class.for_user_project(user, project)
      expect(result.view_type).to eq('tickets')
    end

    it 'respects explicit view_type parameter' do
      result = described_class.for_user_project(user, project, 'documents')
      expect(result.view_type).to eq('documents')
    end

    it 'does not set defaults on existing record' do
      custom_columns = %w[number title tags]
      create(:view_configuration, organisation: organisation, user: user, project: project,
                                  view_type: 'tickets', table_columns: custom_columns)

      result = described_class.for_user_project(user, project, 'tickets')
      expect(result.table_columns).to eq(custom_columns)
    end
  end

  # ──────────────────────────────────────────────
  # detail_settings: subtasks_display
  # ──────────────────────────────────────────────

  describe 'detail_settings subtasks_display' do
    it 'defaults subtasks_display to full on a raw insert (model default, NOT the factory)' do
      # The factory does not set detail_settings, so this exercises the real default merge of
      # DEFAULT_DETAIL_SETTINGS over the persisted (DB-default {}) value. Flips red if the default
      # key disappears or changes value.
      config = described_class.create!(organisation: organisation, user: user, project: project, view_type: 'tickets')
      expect(config.reload.detail_setting('subtasks_display')).to eq('full')
    end

    it 'accepts and persists every whitelisted subtasks_display value' do
      # Positive iteration over the constant (not hard-coded strings): shrinking the whitelist or
      # mistyping an option makes the corresponding value get dropped on save -> red.
      config = create(:view_configuration, organisation: organisation, user: user, project: project)
      Prosopite.pause # sequential single-row UPDATEs of the same record, not an N+1
      begin
        ViewConfiguration::DETAIL_SETTING_OPTIONS.fetch('subtasks_display').each do |value|
          config.update!(detail_settings: { 'subtasks_display' => value })
          expect(config.reload.detail_setting('subtasks_display')).to eq(value)
        end
      ensure
        Prosopite.resume
      end
    end

    it 'drops an invalid value and falls back to the default' do
      config = build_config(detail_settings: { 'subtasks_display' => 'bogus' })
      config.save!
      expect(config.reload.detail_setting('subtasks_display')).to eq('full')
    end

    it 'falls back to the default when detail_settings is explicitly nil' do
      config = create(:view_configuration, organisation: organisation, user: user, project: project, detail_settings: nil)
      expect(config.reload.detail_setting('subtasks_display')).to eq('full')
      expect(config.subtasks_compact?).to be(false)
    end

    describe '#subtasks_compact?' do
      it 'is false by default (full)' do
        expect(build_config.subtasks_compact?).to be(false)
      end

      it 'is true when set to compact' do
        expect(build_config(detail_settings: { 'subtasks_display' => 'compact' }).subtasks_compact?).to be(true)
      end
    end
  end

  # ──────────────────────────────────────────────
  # #ordered_columns (doc/spaltenwahl_plan.md, D1)
  # ──────────────────────────────────────────────

  describe '#ordered_columns' do
    it 'is the table columns, required first, blanks and duplicates out' do
      config = build_config(table_columns: ['tags', '', 'number', 'tags', nil, 'assignees'], list_columns: nil)
      expect(config.ordered_columns).to eq(%w[number title tags assignees])
    end

    it 'folds the legacy second list in behind the table columns: cells, then fields below the title' do
      config = build_config(table_columns: %w[number title assignees],
                            list_columns: { 'cells' => %w[created_at assignees], 'metadata' => %w[tags] })
      expect(config.ordered_columns).to eq(%w[number title assignees created_at tags])
    end

    it 'folds a legacy Array in the same way' do
      config = build_config(table_columns: %w[number title], list_columns: %w[title tags])
      expect(config.ordered_columns).to eq(%w[number title tags])
    end

    it 'ignores a second list of an unexpected type' do
      config = build_config(table_columns: %w[number title tags])
      config.list_columns = 'garbage'
      expect(config.ordered_columns).to eq(%w[number title tags])
    end

    it 'is the required two when nothing is stored' do
      config = build_config(table_columns: nil, list_columns: nil)
      expect(config.ordered_columns).to eq(%w[number title])
    end
  end

  describe '.normalize_columns' do
    it 'accepts symbols, drops blanks and duplicates, puts number and title first' do
      expect(described_class.normalize_columns([:tags, 'title', '', nil, 'tags', 'number'])).to eq(%w[number title tags])
    end

    it 'answers the required two for nil' do
      expect(described_class.normalize_columns(nil)).to eq(%w[number title])
    end
  end

  describe '.column_min_width' do
    it 'reads the key first, then the type, then the default' do
      expect(described_class.column_min_width(key: 'assignees', type: 'users')).to eq(120)
      expect(described_class.column_min_width(key: 'custom_x', type: 'select')).to eq(110)
      expect(described_class.column_min_width(key: 'custom_y', type: 'color')).to eq(described_class::DEFAULT_COLUMN_MIN_WIDTH_PX)
    end
  end

  describe '.default_columns_for (plan D7)' do
    it 'is number, title, assignees, created_at for a project without a status attribute' do
      expect(described_class.default_columns_for(project)).to eq(%w[number title assignees created_at])
    end

    it 'puts the status attribute third when the project has one' do
      create(:ticket_attribute_definition, :select, project: project, name: 'phase',
                                                    options: { 'allowed_values' => [
                                                      { 'value' => 'neu', 'labels' => { 'de' => 'Neu', 'en' => 'New' },
                                                        'system_functions' => [SystemFunctions::Registry::IS_OPEN] }
                                                    ] })
      expect(described_class.default_columns_for(project)).to eq(%w[number title custom_phase assignees created_at])
    end

    it 'is what a fresh configuration starts with' do
      config = described_class.for_user_project(user, project, 'tickets')
      expect(config.table_columns).to eq(described_class.default_columns_for(project))
      expect(config.list_columns).to be_blank
    end
  end

  # ──────────────────────────────────────────────
  # before_save :ensure_required_columns
  # ──────────────────────────────────────────────

  describe '#ensure_required_columns (before_save)' do
    describe 'table_columns' do
      it 'prepends required columns' do
        config = build_config(table_columns: %w[tags])
        config.save!
        expect(config.table_columns.first(2)).to eq(%w[number title])
        expect(config.table_columns).to include('tags')
      end

      it 'deduplicates when required columns already present' do
        config = build_config(table_columns: %w[number title assignees number])
        config.save!
        expect(config.table_columns.count('number')).to eq(1)
      end

      it 'removes blank strings' do
        config = build_config(table_columns: ['tags', '', '  ', nil])
        config.save!
        expect(config.table_columns).not_to include('', '  ', nil)
      end

      it 'uses required columns when table_columns is nil' do
        config = build_config(table_columns: nil)
        config.save!
        expect(config.table_columns).to eq(ViewConfiguration::DEFAULT_REQUIRED_COLUMNS)
      end
    end

    describe 'the legacy second list' do
      it 'is retired by the list writer even when table_columns comes out unchanged (an unticked folded-in field must not come back)' do
        config = build_config(table_columns: %w[number title assignees])
        config.save!
        config.update_columns(list_columns: { 'cells' => %w[tags], 'metadata' => [] })
        expect(config.reload.ordered_columns).to eq(%w[number title assignees tags])

        config.update!(ordered_columns: %w[number title assignees])

        expect(config.reload.list_columns).to be_nil
        expect(config.ordered_columns).to eq(%w[number title assignees])
      end

      it 'is retired by a plain write that changes table_columns' do
        config = build_config(table_columns: %w[number title assignees])
        config.save!
        config.update_columns(list_columns: { 'cells' => %w[tags], 'metadata' => [] })

        config.reload.update!(table_columns: %w[number title created_at])

        expect(config.reload.list_columns).to be_nil
        expect(config.ordered_columns).to eq(%w[number title created_at])
      end

      it 'survives a write that leaves table_columns alone' do
        config = build_config(table_columns: %w[number title assignees])
        config.save!
        config.update_columns(list_columns: { 'cells' => %w[tags], 'metadata' => [] })

        config.reload.update!(view_mode: 'kanban')

        expect(config.reload.list_columns).to eq({ 'cells' => %w[tags], 'metadata' => [] })
        expect(config.ordered_columns).to eq(%w[number title assignees tags])
      end
    end

    describe 'header_columns' do
      it 'preserves valid header columns' do
        config = build_config(header_columns: %w[assignees tags])
        config.save!
        expect(config.header_columns).to eq(%w[assignees tags])
      end

      it 'removes blank strings' do
        config = build_config(header_columns: ['assignees', '', '  '])
        config.save!
        expect(config.header_columns).to eq(%w[assignees])
      end

      it 'uses default when header_columns is nil' do
        config = build_config(header_columns: nil)
        config.save!
        expect(config.header_columns).to eq(ViewConfiguration::DEFAULT_HEADER_COLUMNS)
      end
    end
  end

  # ──────────────────────────────────────────────
  # .available_columns_for / #available_columns
  # ──────────────────────────────────────────────

  describe '.available_columns_for' do
    it 'returns ticket base columns for tickets' do
      columns = described_class.available_columns_for(project, 'tickets')
      keys = columns.map { |c| c[:key] }
      expect(keys).to include('number', 'title', 'assignees', 'tags', 'created_at', 'updated_at')
    end

    it 'marks number and title as required' do
      columns = described_class.available_columns_for(project, 'tickets')
      required = columns.select { |c| c[:required] }.map { |c| c[:key] }
      expect(required).to contain_exactly('number', 'title')
    end

    it 'returns note base columns for notes' do
      columns = described_class.available_columns_for(project, 'notes')
      keys = columns.map { |c| c[:key] }
      expect(keys).to include('title', 'description', 'created_at', 'updated_at')
      expect(keys).not_to include('number', 'assignees')
    end

    it 'returns document base columns for documents' do
      columns = described_class.available_columns_for(project, 'documents')
      keys = columns.map { |c| c[:key] }
      expect(keys).to include('name', 'file_type', 'file_size', 'created_at')
    end

    it 'returns empty array for unknown view_type' do
      expect(described_class.available_columns_for(project, 'unknown')).to eq([])
    end

    context 'with custom ticket attributes' do
      let!(:text_attr) do
        create(:ticket_attribute_definition, project: project, name: 'priority', field_type: 'text',
                                             labels: { 'de' => 'Priorität', 'en' => 'Priority' })
      end
      let!(:select_attr) do
        create(:ticket_attribute_definition, :select, project: project, name: 'status',
                                                      labels: { 'de' => 'Status', 'en' => 'Status' })
      end

      it 'appends active custom attributes to ticket columns' do
        columns = described_class.available_columns_for(project, 'tickets')
        custom_keys = columns.select { |c| c[:custom] }.map { |c| c[:key] }
        expect(custom_keys).to include('custom_priority', 'custom_status')
      end

      it 'excludes inactive custom attributes' do
        text_attr.update!(active: false)
        columns = described_class.available_columns_for(project, 'tickets')
        custom_keys = columns.select { |c| c[:custom] }.map { |c| c[:key] }
        expect(custom_keys).not_to include('custom_priority')
        expect(custom_keys).to include('custom_status')
      end

      it 'does not append custom attributes for non-ticket views' do
        columns = described_class.available_columns_for(project, 'notes')
        expect(columns.none? { |c| c[:custom] }).to be true
      end
    end
  end

  describe '#available_columns' do
    it 'delegates to class method with own project and view_type' do
      config = build_config(view_type: 'documents')
      expect(config.available_columns).to eq(described_class.available_columns_for(project, 'documents'))
    end
  end

  # ──────────────────────────────────────────────
  # #available_header_columns
  # ──────────────────────────────────────────────

  describe '#available_header_columns' do
    it 'returns base header columns without custom attributes' do
      config = build_config
      columns = config.available_header_columns
      keys = columns.map { |c| c[:key] }
      expect(keys).to contain_exactly('assignees', 'tags', 'created_at', 'updated_at')
    end

    context 'with custom ticket attributes' do
      let!(:select_attr) do
        create(:ticket_attribute_definition, :select, project: project, name: 'status',
                                                      labels: { 'de' => 'Status', 'en' => 'Status' })
      end

      it 'includes custom attributes for ticket view' do
        config = build_config(view_type: 'tickets')
        columns = config.available_header_columns
        custom_keys = columns.select { |c| c[:custom] }.map { |c| c[:key] }
        expect(custom_keys).to include('custom_status')
      end

      it 'does not include custom attributes for non-ticket view' do
        config = build_config(view_type: 'notes')
        columns = config.available_header_columns
        expect(columns.none? { |c| c[:custom] }).to be true
      end
    end
  end

  # ──────────────────────────────────────────────
  # Constants
  # ──────────────────────────────────────────────

  describe 'constants' do
    it 'freezes VIEW_MODES' do
      expect(ViewConfiguration::VIEW_MODES).to be_frozen
    end

    it 'freezes DEFAULT_REQUIRED_COLUMNS' do
      expect(ViewConfiguration::DEFAULT_REQUIRED_COLUMNS).to be_frozen
    end

    it 'freezes DEFAULT_TABLE_COLUMNS' do
      expect(ViewConfiguration::DEFAULT_TABLE_COLUMNS).to be_frozen
    end

    it 'freezes DEFAULT_HEADER_COLUMNS' do
      expect(ViewConfiguration::DEFAULT_HEADER_COLUMNS).to be_frozen
    end
  end

  # ──────────────────────────────────────────────
  # Associations
  # ──────────────────────────────────────────────

  describe 'associations' do
    it 'belongs to user' do
      expect(described_class.reflect_on_association(:user).macro).to eq(:belongs_to)
    end

    it 'belongs to project' do
      expect(described_class.reflect_on_association(:project).macro).to eq(:belongs_to)
    end

    it 'optionally belongs to kanban_attribute_definition' do
      assoc = described_class.reflect_on_association(:kanban_attribute_definition)
      expect(assoc.macro).to eq(:belongs_to)
      expect(assoc.options[:optional]).to be true
    end
  end
end
