# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Meetings::ListQuery do
  include ActiveSupport::Testing::TimeHelpers
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, organisation: organisation, user: user, role: create(:admin_role, organisation: organisation))
  end
  after { ActsAsTenant.current_tenant = nil }

  def meeting(title, names: [], **attributes)
    create(:meeting, organisation: organisation, project: project, creator: user, title: title, **attributes).tap do |record|
      names.each { |name| create(:meeting_participant, meeting: record, organisation: organisation, display_name: name) }
    end
  end

  def query(**options)
    described_class.call(scope: project.meetings, **options)
  end

  def save_view(filters, operators = {})
    result = Actors::SaveSmartFolderFromFilters.call(project: project, current_user: user,
                                                     filter_params: filters, operator_params: operators, name: 'Meeting view', target_object_type: 'Meeting')
    expect(result).to be_success
    result.resource.reload
  end

  # occurred_at comes from a form field of minutes, so two meetings entered back
  # to back share it. The one entered last comes first, also against the order
  # of their random ids: the "+" modal on "Alle Meetings" promises the new
  # meeting at the top.
  it 'breaks a tie of the sort column by the time a meeting was entered' do
    at = Time.zone.parse('2026-10-01 10:00')
    older = meeting('Older', id: 'ffffffff-ffff-4fff-bfff-ffffffffffff', occurred_at: at, created_at: 2.minutes.ago)
    newer = meeting('Newer', id: '00000000-0000-4000-8000-000000000000', occurred_at: at, created_at: 1.minute.ago)

    expect(query.map(&:id)).to eq([newer.id, older.id])
    expect(query(sort: { 'column' => 'occurred_at', 'direction' => 'asc' }).map(&:id)).to eq([older.id, newer.id])
  end

  it 'searches titles separately and retains notes, transcript and summaries without requiring release' do
    title = meeting('Needle')
    notes = meeting('Notes', notes: 'Needle')
    transcript = meeting('Transcript', transcript: 'Needle')
    summary = meeting('Summary', generated_summary: 'Needle')
    meeting('Unrelated')
    expect(query(search: 'Needle', search_mode: 'title_only').pluck(:id)).to eq([title.id])
    expect(query(search: 'Needle').pluck(:id)).to contain_exactly(title.id, notes.id, transcript.id, summary.id)
    expect(query(search: '%').count(:all)).to eq(0)
  end

  %w[or and not].each do |operator|
    it "preserves normalized participants, commas and #{operator} through save, dissolve and reload" do
      both = meeting('Both', names: ['Jörg Müller', 'Doe, Jane'])
      one = meeting('One', names: ['Joerg Mueller'])
      neither = meeting('Neither', names: ['Someone else'])
      filters = { 'participant' => ['Jörg Müller', 'Doe, Jane'] }
      operators = { 'participant' => operator }
      folder = save_view(filters, operators)
      expected = case operator
                 when 'or' then [both.id, one.id]
                 when 'and' then [both.id]
                 else [neither.id]
                 end
      expect(query(filters: filters, operators: operators).pluck(:id)).to match_array(expected)
      expect(query(smart_folder: folder).pluck(:id)).to match_array(expected)
      dissolved = SmartFolderDissolver.new(folder).call
      expect(dissolved).to be_dissolvable
      expect(dissolved.ad_hoc_filters).to eq(filters)
      expect(query(filters: dissolved.ad_hoc_filters, operators: dissolved.ad_hoc_operators).pluck(:id)).to match_array(expected)
    end
  end

  it 'uses the same timezone boundaries for multiple date presets and a creator' do
    Time.use_zone('Europe/Berlin') do
      travel_to Time.zone.local(2026, 9, 16, 12) do
        first = meeting('Start', occurred_at: Time.zone.local(2026, 9, 16))
        previous = meeting('Previous', occurred_at: Time.zone.local(2026, 9, 15, 23, 59, 59))
        meeting('Outside', occurred_at: Time.zone.local(2026, 9, 14, 23, 59, 59))
        filters = { 'occurred_at' => %w[today yesterday], 'creator' => [user.id] }
        folder = save_view(filters)
        expect(query(filters: filters).pluck(:id)).to contain_exactly(first.id, previous.id)
        expect(query(smart_folder: folder).pluck(:id)).to contain_exactly(first.id, previous.id)
        expect(SmartFolderDissolver.new(folder).call.ad_hoc_filters).to eq(filters)
      end
    end
  end

  it 'applies advanced content rules to summaries as well as body text' do
    record = meeting('Summary only', generated_summary: 'Unique decision')
    folder = save_view('creator' => [user.id])
    rule = folder.smart_folder_rules.first
    rule.update!(field: 'content', operator: 'contains', value: 'Unique decision')
    expect(query(smart_folder: folder).pluck(:id)).to eq([record.id])
    rule.update!(operator: 'not_contains')
    expect(query(smart_folder: folder)).to be_empty
  end

  it 'never expands its caller scope and orders ties deterministically' do
    records = 3.times.map { meeting('Same', occurred_at: Time.zone.local(2026, 9, 16)) }
    foreign_project = create(:project, organisation: organisation)
    create(:meeting, organisation: organisation, project: foreign_project, creator: user, title: 'Same')
    expect(query.pluck(:id)).to eq(records.map(&:id).sort.reverse)
    expect(query(sort: { 'column' => 'title; DROP TABLE meetings', 'direction' => 'invalid' }).pluck(:id)).to eq(records.map(&:id).sort.reverse)
    folder = save_view('creator' => [user.id])
    expect(described_class.call(scope: project.meetings.where(id: records.first.id), smart_folder: folder).pluck(:id)).to eq([records.first.id])
  end

  it 'preserves the existing All types while allowing unreleased meetings in explicit Meeting views' do
    hidden = meeting('Hidden', notes: 'Content')
    released = meeting('Released', notes: 'Content', create_embeddings: true)
    folder = save_view('creator' => [user.id])
    expect(SmartFolderQueryBuilder.new(folder, user).build_results_query.map(&:id)).to contain_exactly(hidden.id, released.id)
    create(:note, organisation: organisation, project: project, creator: user)
    folder.update!(target_object_type: 'All', sort_column: 'duration_minutes')
    expect(SmartFolderQueryBuilder.new(folder, user).filter_relation(project.meetings).pluck(:id)).to eq([])
    expect(SmartFolderQueryBuilder.new(folder, user).build_results_query.grep(Meeting).map(&:id)).to eq([])
  end
  it 'keeps correlated OR groups complex instead of widening them into independent chips' do
    first = meeting('First', names: ['Anna'])
    second = meeting('Second', names: ['Bert'])
    folder = save_view('creator' => [user.id], 'participant' => ['Anna'])
    group = folder.smart_folder_rule_groups.create!(position: 2)
    group.smart_folder_rules.create!(field: 'creator', operator: 'equals', value: user.id, position: 1)
    group.smart_folder_rules.create!(field: 'participant', operator: 'has_any_of', value: ['Bert'].to_json, position: 2)
    expect(SmartFolderDissolver.new(folder).call).not_to be_dissolvable
    expect(query(smart_folder: folder).pluck(:id)).to contain_exactly(first.id, second.id)
  end

  it 'retains the saved sort when its conditions are edited' do
    first = meeting('A')
    second = meeting('Z')
    folder = save_view('creator' => [user.id])
    folder.update!(sort_column: 'title', sort_direction: 'asc')
    expect(query(smart_folder: folder, apply_folder_rules: false).pluck(:id)).to eq([first.id, second.id])
  end
  it 'rejects empty participant sets instead of silently removing a condition' do
    folder = save_view('participant' => ['Anna'])
    rule = folder.smart_folder_rules.first
    rule.value = '[]'
    expect(rule).not_to be_valid
    expect(rule.errors[:value]).to be_present
  end
  it 'does not dissolve a creator equality combined with an exclusion into a different condition' do
    record = meeting('Mine')
    folder = save_view('creator' => [user.id])
    folder.smart_folder_rule_groups.first.smart_folder_rules.create!(field: 'creator', operator: 'not_equals', value: create(:user, organisation: organisation).id, position: 2)
    expect(SmartFolderDissolver.new(folder).call).not_to be_dissolvable
    expect(query(smart_folder: folder).pluck(:id)).to eq([record.id])
  end
  it 'rejects padded empty or malformed participant sets and fails closed for stored invalid data' do
    meeting('Visible', names: ['Anna'])
    folder = save_view('participant' => ['Anna'])
    rule = folder.smart_folder_rules.sole
    Prosopite.pause # Independent corruption scenarios, not repeated queries in one request.
    [' []', "\n[]", '[" "]', '[123]', '[broken'].each do |value|
      rule.value = value
      expect(rule).not_to be_valid
      rule.update_column(:value, value)
      expect(query(smart_folder: folder.reload)).to be_empty
    end
  ensure
    Prosopite.resume
  end

  it 'treats LIKE wildcards literally in the title-only search' do
    meeting('Needle')
    expect(query(search: '%', search_mode: 'title_only').count(:all)).to eq(0)
    expect(query(search: '_', search_mode: 'title_only').count(:all)).to eq(0)
  end
end
