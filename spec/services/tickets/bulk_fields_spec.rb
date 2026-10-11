# frozen_string_literal: true

require 'rails_helper'

# What: Tickets::BulkFields, the one list of what a bulk change may set
#   (doc/ticket_bulk_edit_plan.md, slice 4).
# Type: service spec.
# Why: the panel's picker, its row templates and the summary all read this list.
#   A text field or an inactive one must never appear, the project's own fields
#   stand first, the three associations (tags, assignees, watchers) are fields
#   like the others with their own options, and the option labels are the ones
#   the reader knows from the list.
RSpec.describe Tickets::BulkFields, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:member) { create(:user, first_name: 'Anna', last_name: 'Berg') }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: member, organisation: organisation, role: create(:admin_role, organisation: organisation))
    create(:tag, name: 'backend', organisation: organisation)
    create(:tag, name: 'api', organisation: organisation)
  end
  after { ActsAsTenant.current_tenant = nil }

  def define(name, type, position:, labels: { 'de' => name.humanize, 'en' => name.humanize }, options: {}, active: true)
    create(:ticket_attribute_definition, project: project, name: name, field_type: type, position: position,
                                         labels: labels, options: options, active: active)
  end

  before do
    define('priority', 'select', position: 2, labels: { 'de' => 'Priorität', 'en' => 'Priority' },
                                 options: { 'allowed_values' => [{ 'value' => 'high', 'labels' => { 'de' => 'Hoch', 'en' => 'High' } }] })
    define('status', 'select', position: 1, labels: { 'de' => 'Status', 'en' => 'Status' },
                               options: { 'allowed_values' => [
                                 { 'value' => 'open', 'labels' => { 'de' => 'offen', 'en' => 'open' } },
                                 { 'value' => 'wip', 'labels' => { 'de' => 'in Arbeit', 'en' => 'in progress' } }
                               ] })
    define('due_date', 'date', position: 3, labels: { 'de' => 'Frist', 'en' => 'Due' }, options: { 'deadline' => true })
    define('reviewed', 'checkbox', position: 4, labels: { 'de' => 'Geprüft', 'en' => 'Reviewed' })
    define('component', 'multiselect', position: 5, labels: { 'de' => 'Komponente', 'en' => 'Component' },
                                       options: { 'allowed_values' => [{ 'value' => 'api', 'labels' => { 'de' => 'API', 'en' => 'API' } }] })
    define('notes', 'text', position: 6)
    define('old', 'select', position: 7, active: false, options: { 'allowed_values' => [] })
  end

  it 'offers every kind, the project fields first, then people, then custom, each in its own order' do
    fields = described_class.for(project: project, user: member, locale: :de)

    expect(fields.map(&:key)).to eq(%w[status priority due_date tags assignees watchers reviewed component])
    expect(fields.map(&:group)).to eq(%w[ticket ticket ticket ticket people people custom custom])
    expect(fields.map(&:kind)).to eq(%w[single single date multi multi multi boolean multi])
  end

  it 'never offers a text field or an inactive field' do
    keys = described_class.for(project: project, user: member).map(&:key)

    expect(keys).not_to include('notes', 'old')
  end

  it 'offers the tags of the organisation by name, and the people who may read the tickets by their shown name' do
    fields = described_class.for(project: project, user: member, locale: :de, name_mode: 'initial_last')

    expect(fields.find { |field| field.key == 'tags' }.options).to eq([{ value: 'api', label: 'api' }, { value: 'backend', label: 'backend' }])
    people = fields.find { |field| field.key == 'assignees' }.options
    expect(people).to include({ value: member.id, label: 'A. Berg' })
    expect(fields.find { |field| field.key == 'watchers' }.options).to eq(people)
  end

  # Without a reader there is no answer to "which tags may be named": the
  # catalogue refuses instead of falling back to every tag of the organisation.
  it 'cannot be built without the user' do
    expect { described_class.for(project: project) }.to raise_error(ArgumentError, /user/)
  end

  it 'lets only the tags take a name nobody has made yet' do
    creatable = described_class.for(project: project, user: member).select(&:creatable).map(&:key)

    expect(creatable).to eq(['tags'])
  end

  # TagPolicy::Scope keeps a tag of a project the reader cannot open out of
  # every tag list; the panel's list was the one that forgot.
  it 'offers a member only the tags used in a project the member can open, an admin every tag' do
    other_project = create(:project, organisation: organisation)
    reader = create(:user)
    create(:membership, user: reader, organisation: organisation, active: true,
                        role: create(:role, organisation: organisation, title: 'Member', is_default: true))
    create(:project_permission, user: reader, project: project, tickets_access: 'read_only')
    create(:tagging, tag: Tag.find_by!(name: 'api'), taggable: create(:ticket, project: project, organisation: organisation))
    create(:tagging, tag: Tag.find_by!(name: 'backend'), taggable: create(:ticket, project: other_project, organisation: organisation))

    tags = ->(user) { described_class.for(project: project, user: user).find { |field| field.key == 'tags' }.options.pluck(:value) }

    expect(tags.call(reader)).to eq(['api'])
    expect(tags.call(member)).to eq(%w[api backend])
  end

  # A recorded run is read back through the reader's catalogue plus the tag
  # names the run itself names, and nothing more (its undo, its result line).
  describe '.for_run' do
    let(:reader) { create(:user) }

    before do
      create(:membership, user: reader, organisation: organisation, active: true,
                          role: create(:role, organisation: organisation, title: 'Member', is_default: true))
      create(:project_permission, user: reader, project: project, tickets_access: 'read_write')
    end

    def run_with(change_list)
      TicketBulkRun.new(project: project, organisation: organisation, change_list: change_list)
    end

    def tag_values(fields)
      fields.find { |field| field.key == 'tags' }.options.pluck(:value)
    end

    it 'offers the tag names the run names, and no other hidden tag' do
      run = run_with([{ 'field' => 'tags', 'kind' => 'multi', 'add' => ['neu'], 'remove' => ['backend'] },
                      { 'field' => 'component', 'kind' => 'multi', 'add' => ['fremd'], 'remove' => [] }])

      fields = described_class.for_run(run: run, user: reader)

      expect(tag_values(fields)).to eq(%w[neu backend])
      expect(tag_values(described_class.for(project: project, user: reader))).to be_empty
      expect(fields.find { |field| field.key == 'component' }.options.pluck(:value)).to eq(['api'])
    end

    it 'adds nothing a reader already has, and leaves a run without tags alone' do
      run = run_with([{ 'field' => 'tags', 'kind' => 'multi', 'add' => ['api'], 'remove' => [] }])

      expect(tag_values(described_class.for_run(run: run, user: member))).to eq(%w[api backend])
      expect(tag_values(described_class.for_run(run: run_with([]), user: member))).to eq(%w[api backend])
    end
  end

  it 'labels fields and options in the reader\'s locale' do
    status = described_class.for(project: project, user: member, locale: :en).find { |field| field.key == 'status' }

    expect(status.label).to eq('Status')
    expect(status.options).to eq([{ value: 'open', label: 'open' }, { value: 'wip', label: 'in progress' }])
    expect(described_class.for(project: project, user: member, locale: :de).find { |field| field.key == 'status' }.options.last[:label]).to eq('in Arbeit')
  end

  it 'gives a date and a boolean no options' do
    fields = described_class.for(project: project, user: member)

    expect(fields.find { |field| field.key == 'due_date' }.options).to eq([])
    expect(fields.find { |field| field.key == 'reviewed' }.options).to eq([])
  end
end
