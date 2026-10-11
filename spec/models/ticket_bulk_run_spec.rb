# frozen_string_literal: true

# == Schema Information
#
# Table name: ticket_bulk_runs
#
#  id              :uuid             not null, primary key
#  change_list     :jsonb            not null
#  changed_count   :integer          default(0), not null
#  failed_count    :integer          default(0), not null
#  results         :jsonb            not null
#  undone_at       :datetime
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  project_id      :uuid             not null
#  undo_of_id      :uuid
#  user_id         :uuid
#
# Indexes
#
#  index_ticket_bulk_runs_on_organisation_id  (organisation_id)
#  index_ticket_bulk_runs_on_project_id       (project_id)
#  index_ticket_bulk_runs_on_undo_of_id       (undo_of_id)
#  index_ticket_bulk_runs_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (undo_of_id => ticket_bulk_runs.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => nullify
#
require 'rails_helper'

# What: TicketBulkRun, the record of one bulk change (doc/ticket_bulk_edit_plan.md, D8).
# Type: model spec.
# Why: "Rückgängig" is offered by the runner or an account admin, inside the
#   window, once, and only for a run that changed something and is not itself
#   an undo. Each of these is a line here.
RSpec.describe TicketBulkRun do
  let(:organisation) { create(:organisation) }
  let(:runner) { create(:user) }
  let(:other) { create(:user) }
  let(:admin) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: runner, organisation: organisation, role: create(:role, organisation: organisation))
    create(:membership, user: other, organisation: organisation, role: create(:role, organisation: organisation))
    create(:membership, user: admin, organisation: organisation, role: create(:admin_role, organisation: organisation))
  end
  after { ActsAsTenant.current_tenant = nil }

  def run(**attrs)
    described_class.create!({ organisation: organisation, project: project, user: runner,
                              change_list: [{ 'field' => 'status', 'kind' => 'single', 'value' => 'open' }],
                              results: { 'a' => { 'ok' => true, 'number' => 1, 'before' => { 'status' => 'wip' } },
                                         'b' => { 'ok' => false, 'number' => 2, 'error' => 'invalid' } },
                              changed_count: 1, failed_count: 1 }.merge(attrs))
  end

  it 'reads the ok ids, the failures and the previous values' do
    record = run
    expect(record.ok_ticket_ids).to eq(['a'])
    expect(record.failed_results.keys).to eq(['b'])
    expect(record.before_for('a')).to eq({ 'status' => 'wip' })
    expect(record.before_for('zz')).to eq({})
  end

  it 'can be undone by the runner and by an account admin, not by anyone else' do
    record = run
    expect(record.undoable_by?(runner)).to be(true)
    expect(record.undoable_by?(admin)).to be(true)
    expect(record.undoable_by?(other)).to be(false)
    expect(record.undoable_by?(nil)).to be(false)
  end

  it 'cannot be undone twice, after the window, as an undo, or when nothing changed' do
    expect(run(undone_at: Time.current).undoable?).to be(false)
    expect(run(created_at: (described_class::UNDO_WINDOW + 1.minute).ago).undoable?).to be(false)
    expect(run(created_at: (described_class::UNDO_WINDOW - 1.minute).ago).undoable?).to be(true)
    expect(run(undo_of: run).undoable?).to be(false)
    expect(run(changed_count: 0, failed_count: 2).undoable?).to be(false)
  end

  it 'is a change by default, and only a change can be undone' do
    expect(run.kind).to eq('change')
    expect(run(kind: 'move', change_list: [{ 'kind' => 'move', 'target_project_name' => 'Ziel' }])).to have_attributes(move?: true, undoable?: false, target_project_name: 'Ziel')
    expect(run(kind: 'delete')).to have_attributes(delete?: true, undoable?: false)
    expect { run(kind: 'archive') }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it 'keeps the run when the runner is gone' do
    record = run(user: nil)
    expect(record).to be_persisted
    expect(record.undoable_by?(admin)).to be(true)
    expect(record.undoable_by?(other)).to be(false)
  end
end
