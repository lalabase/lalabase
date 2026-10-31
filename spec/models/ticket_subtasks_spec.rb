# frozen_string_literal: true

require 'rails_helper'

# Sub-tasks: self-referential parent_id, any depth, same project + org, parent fixed after create.
# Covers the invariants, children_progress, the delete-orphan contract and top_level.
RSpec.describe Ticket, 'sub-tasks', type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def create_status_def(proj, options_list)
    allowed_values = options_list.map do |value, functions|
      entry = { 'value' => value, 'labels' => { 'de' => value } }
      entry['system_functions'] = functions if functions
      entry
    end
    create(:ticket_attribute_definition,
           project: proj, name: 'status', field_type: 'select', system: true,
           options: { 'allowed_values' => allowed_values })
  end

  describe 'invariant validations' do
    let(:parent) { create(:ticket, project: project) }

    it 'accepts a child in the same project' do
      child = build(:ticket, project: project, parent: parent)
      expect(child).to be_valid
    end

    it 'rejects a ticket that is its own parent' do
      parent.parent_id = parent.id
      expect(parent).not_to be_valid
      expect(parent.errors[:parent_id]).to include(I18n.t('activerecord.errors.models.ticket.attributes.parent_id.cannot_be_self'))
    end

    it 'rejects a non-existent parent_id as not_found (not silently nil)' do
      child = build(:ticket, project: project, parent_id: SecureRandom.uuid)
      expect(child).not_to be_valid
      expect(child.errors[:parent_id]).to include(I18n.t('activerecord.errors.models.ticket.attributes.parent_id.not_found'))
    end

    it 'rejects a cross-tenant parent as not_found (acts_as_tenant scopes it to nil)' do
      other_org = create(:organisation)
      foreign_parent = ActsAsTenant.with_tenant(other_org) do
        create(:ticket, project: create(:project, organisation: other_org))
      end

      child = build(:ticket, project: project, parent_id: foreign_parent.id)
      expect(child).not_to be_valid
      expect(child.errors[:parent_id]).to include(I18n.t('activerecord.errors.models.ticket.attributes.parent_id.not_found'))
    end

    it 'rejects a parent in a different project of the same org' do
      other_project = create(:project, organisation: organisation)
      foreign_parent = create(:ticket, project: other_project)

      child = build(:ticket, project: project, parent_id: foreign_parent.id)
      expect(child).not_to be_valid
      expect(child.errors[:parent_id]).to include(I18n.t('activerecord.errors.models.ticket.attributes.parent_id.different_project'))
    end

    it 'accepts a grandchild and a great-grandchild (depth is unlimited)' do
      child = create(:ticket, project: project, parent: parent)
      grandchild = create(:ticket, project: project, parent: child)
      great_grandchild = build(:ticket, project: project, parent: grandchild)

      expect(great_grandchild).to be_valid
      great_grandchild.save!
      expect(great_grandchild.reload.parent_id).to eq(grandchild.id)
      expect(grandchild.reload.parent_id).to eq(child.id)
    end
  end

  describe 'the parent is fixed once the ticket exists' do
    let(:cannot_change) { I18n.t('activerecord.errors.models.ticket.attributes.parent_id.cannot_change') }

    it 'refuses giving a parent to a saved childless top-level ticket' do
      ticket = create(:ticket, project: project)
      ticket.parent = create(:ticket, project: project)

      expect(ticket).not_to be_valid
      expect(ticket.errors[:parent_id]).to include(cannot_change)
      expect(ticket.reload.parent_id).to be_nil
    end

    it 'refuses moving a saved child to another parent' do
      first_parent = create(:ticket, project: project)
      child = create(:ticket, project: project, parent: first_parent)
      child.parent = create(:ticket, project: project)

      expect(child).not_to be_valid
      expect(child.errors[:parent_id]).to include(cannot_change)
      expect(child.reload.parent_id).to eq(first_parent.id)
    end

    it 'refuses detaching a saved child (parent to nil is a change as well)' do
      parent = create(:ticket, project: project)
      child = create(:ticket, project: project, parent: parent)
      child.parent_id = nil

      expect(child).not_to be_valid
      expect(child.errors[:parent_id]).to include(cannot_change)
      expect(child.reload.parent_id).to eq(parent.id)
    end

    it 'refuses giving a parent to a ticket that already has children' do
      parent = create(:ticket, project: project)
      create(:ticket, project: project, parent: parent)
      parent.parent = create(:ticket, project: project)

      expect(parent).not_to be_valid
      expect(parent.errors[:parent_id]).to include(cannot_change)
    end

    it 'cannot close a cycle A -> B -> A through the model' do
      a = create(:ticket, project: project)
      b = create(:ticket, project: project, parent: a)
      a.parent = b

      expect(a.save).to be(false)
      expect(a.errors[:parent_id]).to include(cannot_change)
      expect(a.reload.parent_id).to be_nil
      expect(b.reload.parent_id).to eq(a.id)
    end

    it 'still saves other changes of a ticket with a parent' do
      parent = create(:ticket, project: project)
      child = create(:ticket, project: project, parent: parent)
      child.title = 'Renamed'

      expect(child.save).to be(true)
      expect(child.reload.parent_id).to eq(parent.id)
    end
  end

  describe '#children_progress' do
    let(:parent) { create(:ticket, project: project) }

    it 'is nil when there are no children' do
      expect(parent.children_progress).to be_nil
    end

    it 'counts children whose status carries a closed System Function as done' do
      create_status_def(project, [['Offen', ['is_new']], ['Erledigt', ['is_completed']]])
      create(:ticket, project: project, parent: parent, custom_attributes: { 'status' => 'Erledigt' })
      create(:ticket, project: project, parent: parent, custom_attributes: { 'status' => 'Erledigt' })
      create(:ticket, project: project, parent: parent, custom_attributes: { 'status' => 'Offen' })

      expect(parent.children_progress).to eq(done: 2, total: 3, percent: 66)
    end

    it 'integer-floors the percent (1 of 3 -> 33), which is what the progress bar needs' do
      # Separate create calls (not a loop): the project's Prosopite guard flags a create loop as
      # an N+1 because each ticket validates its custom attributes against the attribute_definitions.
      create_status_def(project, [['Offen', ['is_new']], ['Erledigt', ['is_completed']]])
      create(:ticket, project: project, parent: parent, custom_attributes: { 'status' => 'Erledigt' })
      create(:ticket, project: project, parent: parent, custom_attributes: { 'status' => 'Offen' })
      create(:ticket, project: project, parent: parent, custom_attributes: { 'status' => 'Offen' })

      expect(parent.children_progress).to eq(done: 1, total: 3, percent: 33)
    end

    it 'counts an untriaged (no status) child as not-done' do
      create_status_def(project, [['Erledigt', ['is_completed']]])
      create(:ticket, project: project, parent: parent, custom_attributes: {})

      expect(parent.children_progress).to eq(done: 0, total: 1, percent: 0)
    end

    it 'yields done: 0 when the project tags no status as closed' do
      create_status_def(project, [['Offen', ['is_new']], ['Done', nil]])
      create(:ticket, project: project, parent: parent, custom_attributes: { 'status' => 'Done' })

      expect(parent.children_progress).to eq(done: 0, total: 1, percent: 0)
    end

    it 'reports 100 percent when every child is done (upper boundary)' do
      create_status_def(project, [['Erledigt', ['is_completed']]])
      create(:ticket, project: project, parent: parent, custom_attributes: { 'status' => 'Erledigt' })
      create(:ticket, project: project, parent: parent, custom_attributes: { 'status' => 'Erledigt' })

      expect(parent.children_progress).to eq(done: 2, total: 2, percent: 100)
    end

    it 'counts only direct children, not grandchildren' do
      create_status_def(project, [['Offen', ['is_new']], ['Erledigt', ['is_completed']]])
      child = create(:ticket, project: project, parent: parent, custom_attributes: { 'status' => 'Offen' })
      create(:ticket, project: project, parent: child, custom_attributes: { 'status' => 'Erledigt' })
      create(:ticket, project: project, parent: child, custom_attributes: { 'status' => 'Erledigt' })

      expect(parent.children_progress).to eq(done: 0, total: 1, percent: 0)
    end

    it 'is scoped to the parent project: a status another project marks closed does NOT count' do
      # The done-calc must use closed_status_values_for([parent.project_id]), not a global lookup.
      # Here project has no closed status; only a sibling project marks 'Erledigt' as completed.
      sibling_project = create(:project, organisation: organisation)
      create_status_def(sibling_project, [['Erledigt', ['is_completed']]])
      create(:ticket, project: project, parent: parent, custom_attributes: { 'status' => 'Erledigt' })

      expect(parent.children_progress).to eq(done: 0, total: 1, percent: 0)
    end
  end

  describe 'delete-orphan contract' do
    it 'nullifies children on parent destroy (app-level dependent: :nullify)' do
      parent = create(:ticket, project: project)
      child = create(:ticket, project: project, parent: parent)

      parent.destroy

      # Child survives (NOT cascade-destroyed) and is orphaned. Flips red if dependent: :nullify
      # becomes dependent: :destroy (child gone) or :restrict (destroy raises).
      expect(Ticket.exists?(child.id)).to be(true)
      expect(child.reload.parent_id).to be_nil
    end

    it 'nullifies children at the DB level when the app callback is bypassed (FK on_delete: :nullify)' do
      parent = create(:ticket, project: project)
      child = create(:ticket, project: project, parent: parent)

      # `delete` skips the dependent: :nullify callback, so this exercises the DB foreign key ALONE
      # (defense in depth). Flips red if the migration loses on_delete: :nullify: NO ACTION would
      # raise InvalidForeignKey, :cascade would delete the child (reload -> RecordNotFound).
      parent.delete

      expect(child.reload.parent_id).to be_nil
    end
  end

  describe 'deleting the middle ticket of three levels' do
    it 'makes its child top-level and leaves the grandchild on that child' do
      root = create(:ticket, project: project)
      middle = create(:ticket, project: project, parent: root)
      child = create(:ticket, project: project, parent: middle)
      grandchild = create(:ticket, project: project, parent: child)

      middle.destroy

      # dependent: :nullify writes with update_all, past the fixed-parent validation.
      expect(child.reload.parent_id).to be_nil
      expect(grandchild.reload.parent_id).to eq(child.id)
      expect(Ticket.exists?(root.id)).to be(true)
    end
  end

  describe 'defaults' do
    it 'has no parent by default (parent_id stays nil on a fresh ticket)' do
      expect(create(:ticket, project: project).parent_id).to be_nil
    end
  end

  describe '.top_level' do
    it 'returns only tickets without a parent' do
      parent = create(:ticket, project: project)
      child = create(:ticket, project: project, parent: parent)

      expect(Ticket.top_level).to include(parent)
      expect(Ticket.top_level).not_to include(child)
    end
  end
end
