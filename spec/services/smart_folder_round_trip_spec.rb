# frozen_string_literal: true

require 'rails_helper'

# The round trip of doc/filter_datumsvorgaben_rundlauf_plan.md: what the bar
# saves (Actors::SaveSmartFolderFromFilters) the bar reads back
# (SmartFolderDissolver) as the conditions it started from. A condition the bar
# can save but not read back locks the view (D4 of doc/filterleiste_s1_s4_plan.md),
# which is the bug of 08.09.2026: "Erstellt: diese Woche" came back as a frozen
# day count, and the save row offered only "Verwerfen".
RSpec.describe 'Smart folder round trip: saved from the bar, read back into the bar' do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:other) { create(:user, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    create(:project_permission, user: user, project: project, tickets_access: 'read_write')
    create(:ticket_attribute_definition, project: project, name: 'frist', field_type: 'date',
                                         labels: { 'de' => 'Frist', 'en' => 'Deadline' }, options: { 'deadline' => true })
  end

  after { ActsAsTenant.current_tenant = nil }

  def save_from_bar(filters, operators = {})
    result = Actors::SaveSmartFolderFromFilters.call(
      project: project, current_user: user, filter_params: filters, operator_params: operators, name: 'Rundlauf'
    )
    expect(result).to be_success, -> { "the save failed: #{result.error}" }
    result.resource.reload
  end

  def round_trip(filters, operators = {})
    SmartFolderDissolver.new(save_from_bar(filters, operators), user).call
  end

  SmartFolders::DatePresets::KEYS.each do |preset|
    it "reads 'Erstellt: #{preset}' back as itself" do
      dissolved = round_trip('created_at' => [preset])
      expect(dissolved).to be_dissolvable
      expect(dissolved.ad_hoc_filters).to eq('created_at' => [preset])
      expect(dissolved.ad_hoc_operators).to eq({})
    end
  end

  Ticket::DUE_DATE_PRESET_KEYS.each do |preset|
    it "reads 'Fälligkeit: #{preset}' back as itself" do
      dissolved = round_trip('due_date' => [preset])
      expect(dissolved).to be_dissolvable
      expect(dissolved.ad_hoc_filters).to eq('due_date' => [preset])
    end
  end

  # The waiting states (doc/ticket_relations_plan.md, revision 4, §9): a flag with "ist" and
  # "ist nicht". Read back as anything else, the view would open with an expert rule.
  %w[waiting blocking].each do |field|
    [nil, 'not'].each do |operator|
      it "reads '#{field}' #{operator || 'or'} back as itself" do
        operators = operator ? { field => operator } : {}
        dissolved = round_trip({ field => ['true'] }, operators)
        expect(dissolved).to be_dissolvable
        expect(dissolved.ad_hoc_filters).to eq(field => ['true'])
        expect(dissolved.ad_hoc_operators).to eq(operators)
      end
    end
  end

  it 'reads both states next to a status, a tag and two assignees back unchanged' do
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                         options: { 'allowed_values' => [{ 'value' => 'Offen', 'labels' => { 'de' => 'Offen' } }] })
    filters = { 'waiting' => ['true'], 'blocking' => ['true'], 'status' => ['Offen'], 'tag' => ['bug'],
                'assignee' => [user.id.to_s, other.id.to_s] }
    dissolved = round_trip(filters, { 'waiting' => 'not' })

    expect(dissolved).to be_dissolvable
    expect(dissolved.ad_hoc_filters.transform_values(&:sort)).to eq(filters.transform_values(&:sort))
    expect(dissolved.ad_hoc_operators).to eq('waiting' => 'not')
  end

  it 'reads two presets of one category back as the same two (OR)' do
    dissolved = round_trip('updated_at' => %w[today yesterday])
    expect(dissolved).to be_dissolvable
    expect(dissolved.ad_hoc_filters).to eq('updated_at' => %w[today yesterday])
    expect(dissolved.ad_hoc_operators).to eq({})
  end

  it 'reads a preset next to two assignees and a tag back unchanged (the cross product)' do
    dissolved = round_trip('created_at' => ['this_week'], 'assignee' => [user.id.to_s, other.id.to_s], 'tag' => ['bug'])
    expect(dissolved).to be_dissolvable
    expect(dissolved.ad_hoc_filters['created_at']).to eq(['this_week'])
    expect(dissolved.ad_hoc_filters['assignee']).to contain_exactly(user.id.to_s, other.id.to_s)
    expect(dissolved.ad_hoc_filters['tag']).to eq(['bug'])
  end

  it 'renders the label of every preset in both locales (the locale guards do not see a missing EN key)' do
    %i[de en].each do |locale|
      I18n.with_locale(locale) do
        SmartFolders::DatePresets::KEYS.each do |preset|
          expect(I18n.t("smart_folders.operators.#{preset}", raise: true)).to be_present
        end
      end
    end
  end

  it 'keeps the meaning, not the day: "diese Woche" saved on a Tuesday still means this week on Friday' do
    folder = travel_to(Time.zone.local(2026, 9, 8, 12, 0)) { save_from_bar('created_at' => ['this_week']) } # a Tuesday
    rule = folder.smart_folder_rule_groups.first.smart_folder_rules.first
    expect(rule).to have_attributes(field: 'created_at', operator: 'this_week', value: nil)

    travel_to(Time.zone.local(2026, 9, 11, 12, 0)) do # the Friday of that week
      monday = create(:ticket, project: project).tap { |t| t.update_column(:created_at, Time.zone.local(2026, 9, 7, 8, 0)) }
      sunday = create(:ticket, project: project).tap { |t| t.update_column(:created_at, Time.zone.local(2026, 9, 6, 8, 0)) }

      ids = SmartFolders::Filters::DateFilter.new(rule).apply(Ticket.where(project: project), 'Ticket').pluck(:id)
      expect(ids).to include(monday.id)
      expect(ids).not_to include(sunday.id)
    end
  end
end
