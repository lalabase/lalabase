# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TicketAttributeDefinition, :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation) }

  def select_definition(name:, values:, **overrides)
    create(:ticket_attribute_definition, :select,
           project: project,
           name: name,
           options: { 'allowed_values' => values.map { |v| { 'value' => v, 'labels' => { 'de' => v, 'en' => v } } } },
           **overrides)
  end

  describe '#ordered_value_keys' do
    it 'returns option values in configured order' do
      definition = select_definition(name: 'priority', values: %w[low normal high])

      expect(definition.ordered_value_keys).to eq(%w[low normal high])
    end

    it 'returns [] for non-select fields' do
      definition = create(:ticket_attribute_definition, project: project, field_type: 'text')

      expect(definition.ordered_value_keys).to eq([])
    end
  end

  describe '.ordered_value_keys_for' do
    it 'finds the active select definition by name and returns its ordered keys' do
      select_definition(name: 'status', values: %w[open in_progress closed])

      expect(described_class.ordered_value_keys_for(project, 'status')).to eq(%w[open in_progress closed])
    end

    it 'returns [] when no matching definition exists' do
      expect(described_class.ordered_value_keys_for(project, 'status')).to eq([])
    end

    it 'ignores inactive definitions' do
      select_definition(name: 'status', values: %w[open closed], active: false)

      expect(described_class.ordered_value_keys_for(project, 'status')).to eq([])
    end

    it 'is scoped to the given project' do
      select_definition(name: 'status', values: %w[open closed])
      other_project = create(:project, organisation: organisation)

      expect(described_class.ordered_value_keys_for(other_project, 'status')).to eq([])
    end
  end

  # The filter bar reads `waiting` and `blocking` as the waiting states (AdHocFilterService),
  # never as a project field: a field of that name would be unreachable in the bar, filter
  # nothing and drop out of a saved view (review of #950). Older special names (due_date, ...)
  # are in use as field names and stay allowed.
  describe 'reserved names' do
    %w[waiting blocking].each do |name|
      it "refuses #{name} for a new field, in both locales" do
        %i[de en].each do |locale|
          I18n.with_locale(locale) do
            definition = build(:ticket_attribute_definition, project: project, name: name)
            expect(definition).not_to be_valid
            expect(definition.errors.details[:name]).to include(error: :reserved)
            expect(definition.errors[:name].join).not_to include('translation missing')
          end
        end
      end

      it "refuses renaming a field to #{name}" do
        definition = create(:ticket_attribute_definition, project: project, name: 'zustand')
        definition.name = name
        expect(definition).not_to be_valid
      end

      it "keeps an existing #{name} field valid when something else changes" do
        definition = create(:ticket_attribute_definition, project: project, name: 'zustand')
        definition.update_column(:name, name)
        definition.reload.position = 7
        expect(definition).to be_valid
      end
    end

    it 'still allows due_date' do
      expect(build(:ticket_attribute_definition, project: project, name: 'due_date', field_type: 'date')).to be_valid
    end
  end

  describe 'date field type' do
    it 'is a valid field_type' do
      definition = build(:ticket_attribute_definition, project: project, field_type: 'date', name: 'due_date')

      expect(definition).to be_valid
    end
  end

  describe '#validate_value for date fields' do
    let(:date_definition) { create(:ticket_attribute_definition, project: project, field_type: 'date', name: 'due_date') }

    it 'accepts a strict ISO date' do
      expect(date_definition.validate_value('2026-06-30')).to be_empty
    end

    it 'accepts blank (optional field)' do
      expect(date_definition.validate_value('')).to be_empty
      expect(date_definition.validate_value(nil)).to be_empty
    end

    it 'rejects an unpadded / non-ISO date' do
      expect(date_definition.validate_value('2026-6-1')).not_to be_empty
    end

    it 'rejects garbage' do
      expect(date_definition.validate_value('not-a-date')).not_to be_empty
    end

    it 'rejects an impossible date' do
      expect(date_definition.validate_value('2026-13-40')).not_to be_empty
    end

    it 'rejects a datetime string (date-only enforced)' do
      expect(date_definition.validate_value('2026-06-30T12:00:00Z')).not_to be_empty
    end
  end

  describe 'deadline marker' do
    def date_def(name, deadline: :unset)
      opts = deadline == :unset ? {} : { 'deadline' => deadline }
      create(:ticket_attribute_definition, project: project, field_type: 'date', name: name, options: opts)
    end

    describe '#deadline?' do
      it 'coerces truthy markers (true / "true" / "1")' do
        expect(date_def('d1', deadline: true).deadline?).to be(true)
        expect(date_def('d2', deadline: 'true').deadline?).to be(true)
        expect(date_def('d3', deadline: '1').deadline?).to be(true)
      end

      it 'coerces falsy / missing markers ("0" / "false" / nil / unset)' do
        expect(date_def('d4').deadline?).to be(false)
        expect(date_def('d5', deadline: '0').deadline?).to be(false)
        expect(date_def('d6', deadline: 'false').deadline?).to be(false)
      end

      it 'is false for non-date fields even if a marker leaks in' do
        sel = create(:ticket_attribute_definition, :select, project: project, name: 'status',
                                                            options: { 'allowed_values' => [{ 'value' => 'open', 'labels' => { 'de' => 'o', 'en' => 'o' } }], 'deadline' => true })
        expect(sel.deadline?).to be(false)
      end
    end

    describe 'normalize-on-write' do
      it 'stores a real boolean in options, not the raw string' do
        definition = date_def('due_date', deadline: '1')
        expect(definition.reload.options['deadline']).to be(true)
      end
    end

    describe 'single-deadline switch' do
      it 'unsets the marker on other date fields when a new one is marked (last wins)' do
        first  = date_def('due_a', deadline: true)
        second = date_def('due_b', deadline: true)

        expect(first.reload.deadline?).to be(false)
        expect(second.reload.deadline?).to be(true)
      end

      # Cross-scope isolation: the switch (#enforce_single_deadline_marker) is scoped per project.
      # This dies if the where(project_id:) scope is dropped — marking one project's deadline would
      # then wrongly unset another project's.
      it "does not touch another project's deadline marker" do
        other_project = create(:project, organisation: organisation)
        other_marked = create(:ticket_attribute_definition, project: other_project,
                                                            field_type: 'date', name: 'due_date',
                                                            options: { 'deadline' => true })

        date_def('due_date', deadline: true) # mark a deadline in `project`

        expect(other_marked.reload.deadline?).to be(true)
      end

      # Composite name uniqueness is scoped to project_id, so the same date-field name (e.g. the
      # canonical 'due_date') may exist in different projects. Dies if `scope: :project_id` is dropped.
      it 'allows the same date-field name in a different project' do
        date_def('due_date', deadline: false)
        other_project = create(:project, organisation: organisation)

        expect(build(:ticket_attribute_definition, project: other_project,
                                                   field_type: 'date', name: 'due_date')).to be_valid
      end
    end

    describe '.deadline_definition_for' do
      it 'returns the marked date field' do
        date_def('other_date', deadline: false)
        marked = date_def('due_date', deadline: true)

        expect(described_class.deadline_definition_for(project)).to eq(marked)
      end

      it 'returns nil when no date field is marked' do
        date_def('due_date', deadline: false)

        expect(described_class.deadline_definition_for(project)).to be_nil
      end
    end
  end

  describe 'priority levels (signal bars)' do
    # Shared option-builder so the create/build variants below can't drift in shape.
    def level_options(levels)
      { 'allowed_values' => levels.each_with_index.map do |lvl, i|
        opt = { 'value' => "v#{i}", 'labels' => { 'de' => "v#{i}", 'en' => "v#{i}" } }
        opt['level'] = lvl unless lvl.nil?
        opt
      end }
    end

    # create persists (use for VALID cases / when you need #reload); build does NOT save (use for
    # INVALID cases — create would raise RecordInvalid instead of returning an invalid record).
    def priority_with_levels(levels)
      create(:ticket_attribute_definition, :select, project: project, name: 'priority', options: level_options(levels))
    end

    def built_priority_with_levels(levels)
      build(:ticket_attribute_definition, :select, project: project, name: 'priority', options: level_options(levels))
    end

    describe '#level_for' do
      it 'returns the option level as index and the field max as total' do
        definition = priority_with_levels([1, 2, 3, 4])

        expect(definition.level_for('v2')).to eq(index: 3, total: 4)
      end

      it 'is nil for a value without a level' do
        expect(priority_with_levels([1, 2]).level_for('missing')).to be_nil
      end
    end

    describe 'normalize-on-write' do
      it 'coerces string levels to integers' do
        definition = create(:ticket_attribute_definition, :select, project: project, name: 'priority',
                                                                   options: { 'allowed_values' => [
                                                                     { 'value' => 'a', 'labels' => { 'de' => 'a', 'en' => 'a' }, 'level' => '1' },
                                                                     { 'value' => 'b', 'labels' => { 'de' => 'b', 'en' => 'b' }, 'level' => '2' },
                                                                     { 'value' => 'c', 'labels' => { 'de' => 'c', 'en' => 'c' }, 'level' => '3' }
                                                                   ] })

        expect(definition.reload.options['allowed_values'].map { |opt| opt['level'] }).to eq([1, 2, 3])
      end
    end

    describe 'validation' do
      # Boundary pairs around the allowed band 1..option_count. The old single "level 9 of 2 options"
      # test survived both `> count` -> `>= count` and a missing lower-bound check; these n / n+1 / 0
      # pairs kill those mutations.
      it 'accepts a top level exactly equal to the option count (upper boundary n)' do
        expect(priority_with_levels([1, 2, 3])).to be_valid # 3 options, top level == 3
      end

      it 'rejects a level one past the option count (upper boundary n+1)' do
        expect(built_priority_with_levels([1, 2, 4])).not_to be_valid # 3 options, level 4
      end

      it 'accepts level 1 as the lowest valid level (lower boundary n)' do
        expect(priority_with_levels([1, 2])).to be_valid
      end

      it 'rejects a zero level (lower boundary n-1, zero-bug)' do
        expect(built_priority_with_levels([0, 2])).not_to be_valid
      end

      it 'requires every option to carry a level once any does' do
        definition = build(:ticket_attribute_definition, :select, project: project, name: 'priority',
                                                                  options: { 'allowed_values' => [
                                                                    { 'value' => 'a', 'labels' => { 'de' => 'a', 'en' => 'a' }, 'level' => 1 },
                                                                    { 'value' => 'b', 'labels' => { 'de' => 'b', 'en' => 'b' } }
                                                                  ] })

        expect(definition).not_to be_valid
      end

      it 'allows a plain select with no levels at all' do
        expect(priority_with_levels([nil, nil])).to be_valid
      end
    end
  end

  # Stored XSS (security test 26.09.2026): the option colour reached a raw `style="..."`
  # attribute. The model is one of three layers, each of which must stop it on its own.
  describe 'option colour validation' do
    def definition_with_color(color)
      build(:ticket_attribute_definition, :select, project: project, name: 'status',
                                                   options: { 'allowed_values' => [
                                                     { 'value' => 'a', 'labels' => { 'de' => 'a', 'en' => 'a' }, 'color' => color }
                                                   ] })
    end

    [
      '#000"><img src=x onerror=alert(1)>',
      'red',
      '#fff',
      '#12345g',
      "#123456\n", # `^...$` would let a trailing newline (and anything after it) through
      "#123456\n<script>",
      '#12345',          # one digit short (boundary n-1): kills `\h{5,6}`
      '#1234567',        # one digit over (boundary n+1): kills `\h{6,}` and a dropped `\z`
      '123456',          # no hash: kills `#?`
      "red\n#123456",    # valid line after a newline: kills `^` instead of `\A`
      ' #123456',        # the model does not strip, only the controller does
      123_456            # not a string at all (jsonb can hold a number)
    ].each do |color|
      it "rejects #{color.inspect}" do
        definition = definition_with_color(color)

        expect(definition).not_to be_valid
        expect(definition.errors.details[:options]).to include(a_hash_including(error: :invalid_option_color))
      end
    end

    ['#3B82F6', '#3b82f6', nil, ''].each do |color|
      it "accepts #{color.inspect}" do
        expect(definition_with_color(color)).to be_valid
      end
    end

    it 'accepts an option without a colour key' do
      expect(build(:ticket_attribute_definition, :select, project: project)).to be_valid
    end

    it 'checks every option, not only the first, and names the offending one' do
      definition = build(:ticket_attribute_definition, :select, project: project, name: 'status',
                                                                options: { 'allowed_values' => [
                                                                  { 'value' => 'ok', 'labels' => { 'de' => 'ok' }, 'color' => '#3B82F6' },
                                                                  { 'value' => 'bad', 'labels' => { 'de' => 'bad' }, 'color' => 'red' }
                                                                ] })

      expect(definition).not_to be_valid
      expect(definition.errors.details[:options]).to eq([{ error: :invalid_option_color, option: 'bad' }])
    end

    it 'checks multiselect fields as well' do
      definition = build(:ticket_attribute_definition, project: project, field_type: 'multiselect',
                                                       options: { 'allowed_values' => [
                                                         { 'value' => 'a', 'labels' => { 'de' => 'a' }, 'color' => 'red' }
                                                       ] })

      expect(definition).not_to be_valid
    end

    it 'has a translated message in both locales' do
      %i[de en].each do |locale|
        I18n.with_locale(locale) do
          definition = definition_with_color('red')
          definition.valid?
          expect(definition.errors.full_messages.join).to include("'a'").and(satisfy { |m| !m.include?('translation missing') })
        end
      end
    end

    # Heads-up from the PR: the validation also bites rows written before it existed.
    # A later save must fail loudly instead of persisting the bad value again.
    it 'refuses to save an existing row that still holds a legacy colour' do
      definition = create(:ticket_attribute_definition, :select, project: project)
      options = definition.options.deep_dup
      options['allowed_values'].first['color'] = 'red; background-image:url(x)'
      definition.update_column(:options, options)

      expect(definition.reload.update(position: 3)).to be(false)
      expect(definition.errors.details[:options]).to include(a_hash_including(error: :invalid_option_color))
    end
  end

  describe '.safe_option_color' do
    it 'returns a valid hex unchanged' do
      expect(described_class.safe_option_color('#3b82f6')).to eq('#3b82f6')
    end

    it 'returns the fallback for anything else' do
      expect(described_class.safe_option_color('red; background-image:url(https://x)', '#f3f4f6')).to eq('#f3f4f6')
      expect(described_class.safe_option_color("#123456\n")).to be_nil
      expect(described_class.safe_option_color(nil, '#000000')).to eq('#000000')
      expect(described_class.safe_option_color(123_456, '#000000')).to eq('#000000')
    end

    it 'defaults the fallback to nil, so callers can tell "no colour" apart' do
      expect(described_class.safe_option_color('red')).to be_nil
    end

    it 'keeps the editor fallback black, the colour the form has always shown' do
      expect(described_class::OPTION_COLOR_FALLBACK).to eq('#000000')
    end
  end
end
