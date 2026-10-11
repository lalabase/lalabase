# frozen_string_literal: true

require 'rails_helper'

# What: The three phases a ticket can be in for the time list (step 3a of
#       doc/zeiten_weitere_filter_plan.md, E1): in backlog, in progress, done.
# Why:  A status is a per-project string. "Done" is not a value but a System
#       Function on a value (is_completed, is_closed), "backlog" likewise
#       (is_backlog). The phases are the one vocabulary that means the same in
#       every project, so the time list can filter across all of them.
RSpec.describe TimeSessions::TicketPhase do
  let(:organisation) { create(:organisation) }
  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.current_tenant = organisation
    status_definition(project_a, [['Neu', ['is_new']], ['In Arbeit', ['is_in_progress']],
                                  ['Backlog', ['is_backlog']], ['Fertig', ['is_completed']]])
    # Another project, other names, the same meanings; "Doing" carries no
    # function at all.
    status_definition(project_b, [['Idee', ['is_backlog']], ['Done', ['is_closed']], ['Doing', nil]])
  end

  after { ActsAsTenant.current_tenant = nil }

  def status_definition(project, values)
    allowed = values.map do |value, functions|
      { 'value' => value, 'labels' => { 'de' => value } }.tap { |entry| entry['system_functions'] = functions if functions }
    end
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                         options: { 'allowed_values' => allowed })
  end

  def ticket(project, status)
    create(:ticket, project: project, organisation: organisation).tap do |record|
      record.update_column(:custom_attributes, status ? { 'status' => status } : {})
    end
  end

  let!(:tickets) do
    {
      a_new: ticket(project_a, 'Neu'), a_working: ticket(project_a, 'In Arbeit'),
      a_backlog: ticket(project_a, 'Backlog'), a_done: ticket(project_a, 'Fertig'),
      a_untriaged: ticket(project_a, nil),
      b_idea: ticket(project_b, 'Idee'), b_done: ticket(project_b, 'Done'), b_doing: ticket(project_b, 'Doing')
    }
  end

  def in_phase(key)
    described_class.tickets(key, project_ids: [project_a.id, project_b.id])
  end

  # The names of EVERY ticket found. A ticket outside the fixture is named by
  # its id, so an extra hit cannot hide behind the lookup (second review).
  def names(relation)
    by_id = tickets.to_h { |name, record| [record.id, name] }
    relation.pluck(:id).map { |id| by_id.fetch(id, id) }
  end

  it 'has three phases, in the order of a ticket\'s life' do
    expect(described_class::KEYS).to eq(%w[backlog active done])
  end

  it 'finds the backlog in every project by its function, not by its name' do
    expect(names(in_phase('backlog'))).to contain_exactly(:a_backlog, :b_idea)
  end

  it 'finds done tickets through is_completed and is_closed alike' do
    expect(names(in_phase('done'))).to contain_exactly(:a_done, :b_done)
  end

  # E1: untriaged is not backlog (the rule of Ticket.active_work), and a value
  # without any function is work in progress too.
  it 'counts everything else as in progress, the untriaged ticket included' do
    expect(names(in_phase('active'))).to contain_exactly(:a_new, :a_working, :a_untriaged, :b_doing)
  end

  # Three phases asked in a row repeat the definitions query on purpose;
  # Prosopite would read the loop as an N+1.
  it 'puts every ticket in exactly one phase' do
    Prosopite.pause
    phases = described_class::KEYS.flat_map { |key| names(in_phase(key)) }
    Prosopite.resume

    expect(phases).to match_array(tickets.keys)
  end

  it 'matches a status in any case, as the stored values vary' do
    tickets[:a_done].update_column(:custom_attributes, { 'status' => 'FERTIG' })

    expect(names(in_phase('done'))).to include(:a_done)
  end

  # A third project uses "Fertig" too, and means done by it. Left out of the
  # given projects, its ticket must stay out, although its value matches.
  it 'looks only at the given projects' do
    project_c = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    status_definition(project_c, [['Fertig', ['is_completed']]])
    ticket(project_c, 'Fertig')

    expect(names(described_class.tickets('done', project_ids: [project_a.id]))).to eq([:a_done])
  end

  # E2 matches values across projects. A value that is backlog in one project
  # and done in another would otherwise be in two phases at once; done wins,
  # so every ticket stays in exactly one (second review).
  it 'puts a value that is backlog here and done there in done only' do
    project_c = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    status_definition(project_c, [['Backlog', ['is_completed']]])
    ids = [project_a.id, project_b.id, project_c.id]

    expect(names(described_class.tickets('done', project_ids: ids))).to include(:a_backlog)
    expect(names(described_class.tickets('backlog', project_ids: ids))).not_to include(:a_backlog)
    expect(names(described_class.tickets('active', project_ids: ids))).not_to include(:a_backlog)
  end

  it 'finds nothing for a phase it does not know' do
    expect(in_phase('junk')).to be_empty
    expect(in_phase(nil)).to be_empty
  end

  it 'knows its keys and nothing else' do
    expect(described_class.valid?('done')).to be(true)
    expect(described_class.valid?('Done')).to be(false)
    expect(described_class.valid?(['done'])).to be(false)
  end

  it 'names every phase in both languages' do
    %i[de en].each do |locale|
      described_class::KEYS.each do |key|
        label = I18n.with_locale(locale) { described_class.label(key) }
        expect(label).to be_present
        expect(label).not_to include('translation missing')
      end
    end
  end
end
