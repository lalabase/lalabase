# frozen_string_literal: true

require 'rails_helper'

# The waiting states as rules of a saved view (doc/ticket_relations_plan.md, revision 4, §9):
# WaitingFilter and BlockingFilter, IS and IS_NOT on a boolean value, the truth table of
# HasTimeSessionsFilter. What "waits" means is Tickets::Waiting's; here the wiring, and the case
# a view across projects adds (§5.2): the same status name means done in one project and open in
# the other, and each ticket is judged by its own.
RSpec.describe SmartFolders::Filters::WaitingStateFilter, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project_x) { create(:project, organisation: organisation) }
  let(:project_y) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    # "Closed" is done in X and still open in Y.
    status_field(project_x, [['Open', ['is_new']], ['Closed', ['is_closed']]])
    status_field(project_y, [['Open', ['is_new']], ['Closed', ['is_in_progress']]])
  end

  after { ActsAsTenant.current_tenant = nil }

  def status_field(project, options_list)
    allowed_values = options_list.map do |value, functions|
      { 'value' => value, 'labels' => { 'de' => value }, 'system_functions' => functions }
    end
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                         options: { 'allowed_values' => allowed_values })
  end

  def ticket(project, status = 'Open')
    Prosopite.pause { create(:ticket, project: project, custom_attributes: { 'status' => status }) }
  end

  def link(source, target, type = :blocks)
    Prosopite.pause { TicketRelation.create!(source_ticket: source, target_ticket: target, relation_type: type) }
  end

  def folder(field, operator, value, project: nil)
    create(:smart_folder, organisation: organisation, user: user, project: project, target_object_type: 'Ticket').tap do |each_folder|
      each_folder.smart_folder_rule_groups.create!(position: 1)
                 .smart_folder_rules.create!(field: field, operator: operator, value: value, position: 1)
    end
  end

  def rule(field, operator, value)
    folder(field, operator, value).smart_folder_rule_groups.first.smart_folder_rules.first
  end

  # blocker (X) -> waiter (X); a blocker in Y that reads "Closed" (open there) -> waits_on_y (X);
  # a blocker in X that reads "Closed" (done there) -> freed (Y); a plain ticket in each project.
  let!(:blocker) { ticket(project_x) }
  let!(:waiter) { ticket(project_x) }
  let!(:open_closed_blocker) { ticket(project_y, 'Closed') }
  let!(:waits_on_y) { ticket(project_x) }
  let!(:done_closed_blocker) { ticket(project_x, 'Closed') }
  let!(:freed) { ticket(project_y) }
  let!(:plain_x) { ticket(project_x) }
  let!(:plain_y) { ticket(project_y) }
  let(:all_ids) { [blocker, waiter, open_closed_blocker, waits_on_y, done_closed_blocker, freed, plain_x, plain_y].map(&:id) }
  let(:waiting_ids) { [waiter.id, waits_on_y.id] }
  let(:blocking_ids) { [blocker.id, open_closed_blocker.id] }

  before do
    link(blocker, waiter)
    link(open_closed_blocker, waits_on_y, :precedes)
    link(done_closed_blocker, freed)
  end

  it 'is the filter class of both rule fields' do
    expect(SmartFolderRule.new(field: 'waiting').get_filter_class).to eq(SmartFolders::Filters::WaitingFilter)
    expect(SmartFolderRule.new(field: 'blocking').get_filter_class).to eq(SmartFolders::Filters::BlockingFilter)
  end

  {
    'waiting' => SmartFolders::Filters::WaitingFilter,
    'blocking' => SmartFolders::Filters::BlockingFilter
  }.each do |field, filter_class|
    describe filter_class do
      let(:in_state) { field == 'waiting' ? waiting_ids : blocking_ids }

      def ids(field, operator, value)
        described_class.new(rule(field, operator, value)).apply(Ticket.all, 'Ticket').pluck(:id)
      end

      it 'IS true keeps the tickets in the state, each judged by its own project' do
        expect(ids(field, SmartFolders::Operators::IS, 'true')).to match_array(in_state)
      end

      it 'IS false keeps the rest, done tickets included' do
        expect(ids(field, SmartFolders::Operators::IS, 'false')).to match_array(all_ids - in_state)
      end

      it 'IS_NOT true keeps the rest' do
        expect(ids(field, SmartFolders::Operators::IS_NOT, 'true')).to match_array(all_ids - in_state)
      end

      it 'IS_NOT false keeps the tickets in the state' do
        expect(ids(field, SmartFolders::Operators::IS_NOT, 'false')).to match_array(in_state)
      end

      it 'leaves other models alone' do
        query = Note.all
        expect(described_class.new(rule(field, SmartFolders::Operators::IS, 'true')).apply(query, 'Note')).to equal(query)
      end
    end
  end

  # The list of an org-wide view goes through SmartFolderQueryBuilder#filter_relation: one view,
  # two projects, two meanings of "Closed".
  describe 'a view across projects' do
    def view_ids(field, operator = SmartFolders::Operators::IS)
      SmartFolderQueryBuilder.new(folder(field, operator, 'true'), user).filter_relation(Ticket.all).pluck(:id)
    end

    it 'judges each end of an edge by its own project' do
      expect(view_ids('waiting')).to contain_exactly(waiter.id, waits_on_y.id)
      expect(view_ids('blocking')).to contain_exactly(blocker.id, open_closed_blocker.id)
      expect(view_ids('waiting', SmartFolders::Operators::IS_NOT)).to include(freed.id)
      expect(view_ids('waiting', SmartFolders::Operators::IS_NOT)).not_to include(waiter.id, waits_on_y.id)
    end

    it 'narrows a project-bound view to its project' do
      view = folder('waiting', SmartFolders::Operators::IS, 'true', project: project_x)
      expect(SmartFolderQueryBuilder.new(view, user).filter_relation(Ticket.all).pluck(:id))
        .to contain_exactly(waiter.id, waits_on_y.id)

      view = folder('blocking', SmartFolders::Operators::IS, 'true', project: project_y)
      expect(SmartFolderQueryBuilder.new(view, user).filter_relation(Ticket.all).pluck(:id)).to eq([open_closed_blocker.id])
    end
  end
end
