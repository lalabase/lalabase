# frozen_string_literal: true

require 'rails_helper'

# What: Tickets::Changes, the registry of what a bulk change does to one ticket
#   (doc/ticket_bulk_edit_plan.md, D13).
# Type: service spec.
# Why: every kind must validate against the catalogue, write what it says,
#   hand back what was there, put it back on restore, and know whether it still
#   holds. A value nobody allowed, a field twice, a plus without a minus and
#   without anything: each is refused before a ticket is touched.
RSpec.describe Tickets::Changes, :bulk_edit do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:member) { create(:user, first_name: 'Anna', last_name: 'Berg') }
  let(:outsider) { create(:user, first_name: 'Otto', last_name: 'Out') }
  let(:project) { create(:project, organisation: organisation) }
  let(:catalogue) { Tickets::BulkFields.for(project: project, user: user, locale: :de) }

  before do
    ActsAsTenant.current_tenant = organisation
    Current.user = user
    create(:membership, user: user, organisation: organisation, role: bulk_admin_role)
    create(:membership, user: member, organisation: organisation, role: bulk_admin_role)
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', position: 1,
                                         labels: { 'de' => 'Status' },
                                         options: { 'allowed_values' => [
                                           { 'value' => 'open', 'labels' => { 'de' => 'offen' } },
                                           { 'value' => 'wip', 'labels' => { 'de' => 'in Arbeit' } }
                                         ] })
    create(:ticket_attribute_definition, project: project, name: 'due_date', field_type: 'date', position: 2,
                                         labels: { 'de' => 'Frist' }, options: { 'deadline' => true })
    create(:ticket_attribute_definition, project: project, name: 'reviewed', field_type: 'checkbox', position: 3,
                                         labels: { 'de' => 'Geprüft' })
    create(:ticket_attribute_definition, project: project, name: 'component', field_type: 'multiselect', position: 4,
                                         labels: { 'de' => 'Komponente' },
                                         options: { 'allowed_values' => [
                                           { 'value' => 'api', 'labels' => { 'de' => 'API' } },
                                           { 'value' => 'web', 'labels' => { 'de' => 'Web' } }
                                         ] })
    create(:tag, name: 'backend', organisation: organisation)
    create(:tag, name: 'doku', organisation: organisation)
  end
  after do
    ActsAsTenant.current_tenant = nil
    Current.user = nil
  end

  let(:ticket) do
    create(:ticket, project: project, organisation: organisation, creator: user,
                    custom_attributes: { 'status' => 'open', 'due_date' => '2026-09-30', 'component' => ['web'] })
  end

  def build(*entries)
    described_class.build(entries, catalogue: catalogue)
  end

  describe '.build' do
    it 'refuses nothing, an unknown field, a field twice, and a value the project does not allow' do
      expect { build }.to raise_error(Tickets::Changes::Invalid) { |e| expect(e.code).to eq(:no_changes) }
      expect { build({ 'field' => 'nope', 'value' => 'x' }) }.to raise_error(Tickets::Changes::Invalid) { |e| expect(e.code).to eq(:unknown_field) }
      expect { build({ 'field' => 'status', 'value' => 'open' }, { 'field' => 'status', 'value' => 'wip' }) }
        .to raise_error(Tickets::Changes::Invalid) { |e| expect(e.code).to eq(:field_twice) }
      expect { build({ 'field' => 'status', 'value' => 'closed' }) }.to raise_error(Tickets::Changes::Invalid) { |e| expect(e.code).to eq(:value_not_allowed) }
      expect { build({ 'field' => 'tags', 'add' => [], 'remove' => [] }) }.to raise_error(Tickets::Changes::Invalid) { |e| expect(e.code).to eq(:nothing_to_change) }
      expect { build({ 'field' => 'due_date', 'value' => '30.09.2026' }) }.to raise_error(Tickets::Changes::Invalid) { |e| expect(e.code).to eq(:date_invalid) }
      expect { build({ 'field' => 'assignees', 'add' => [outsider.id] }) }.to raise_error(Tickets::Changes::Invalid) { |e| expect(e.code).to eq(:value_not_allowed) }
    end

    it 'builds one change per kind, described in words' do
      changes = build({ 'field' => 'status', 'value' => 'wip' }, { 'field' => 'due_date', 'clear' => true },
                      { 'field' => 'tags', 'add' => ['backend'], 'remove' => ['doku'] })
      expect(changes.map(&:class)).to eq([Tickets::Changes::SetSelect, Tickets::Changes::SetDate, Tickets::Changes::AddRemoveTags])
      expect(changes.map(&:describe)).to eq(['Status auf „in Arbeit“ gesetzt', 'Frist entfernt', 'Tags: +backend −doku'])
    end
  end

  # S8 of doc/kanban_ticket_als_bahn_plan.md: the write path is the rule, the
  # board's missing column only a courtesy. The definition answers per ticket,
  # through the field, with the real catalogue (no double: a missing interface
  # cannot hide).
  describe 'a clear of a required select' do
    before do
      create(:ticket_attribute_definition, project: project, name: 'severity', field_type: 'select', position: 5,
                                           labels: { 'de' => 'Schwere' }, validation_rules: { 'required' => true },
                                           options: { 'allowed_values' => [{ 'value' => 'high', 'labels' => { 'de' => 'hoch' } }] })
      create(:ticket_attribute_definition, project: project, name: 'reason', field_type: 'select', position: 6,
                                           labels: { 'de' => 'Grund' },
                                           validation_rules: { 'required' => true, 'required_if' => { 'attribute' => 'status', 'value' => 'wip' } },
                                           options: { 'allowed_values' => [{ 'value' => 'bug', 'labels' => { 'de' => 'Fehler' } }] })
    end

    # The model validates the strictly required field on a normal save, so the
    # ticket of this group carries it from the start.
    let(:ticket) do
      create(:ticket, project: project, organisation: organisation, creator: user,
                      custom_attributes: { 'status' => 'open', 'severity' => 'high', 'component' => ['web'] })
    end

    it 'applies on an optional field, is refused with code required on a strictly required one' do
      expect(build({ 'field' => 'status', 'clear' => true }).first.apply(ticket)).to eq('open')
      expect(ticket.reload.custom_attributes['status']).to be_nil

      expect { build({ 'field' => 'severity', 'clear' => true }).first.apply(ticket) }
        .to raise_error(Tickets::Changes::NotApplicable) { |e| expect(e.code).to eq(:required) }
      expect(ticket.reload.custom_attributes['severity']).to eq('high')
    end

    it 'follows the ticket on a conditional requirement' do
      ticket.update!(custom_attributes: ticket.custom_attributes.merge('reason' => 'bug'))
      expect(build({ 'field' => 'reason', 'clear' => true }).first.apply(ticket)).to eq('bug')

      ticket.update!(custom_attributes: ticket.custom_attributes.merge('status' => 'wip', 'reason' => 'bug'))
      expect { build({ 'field' => 'reason', 'clear' => true }).first.apply(ticket) }
        .to raise_error(Tickets::Changes::NotApplicable) { |e| expect(e.code).to eq(:required) }
    end
  end

  describe 'select, date and yes/no' do
    it 'writes, hands back the previous value, restores it, and knows whether it still holds' do
      change = build({ 'field' => 'status', 'value' => 'wip' }).first
      before = change.apply(ticket)
      expect(before).to eq('open')
      expect(ticket.reload.custom_attributes['status']).to eq('wip')
      expect(change.still_applied?(ticket)).to be(true)
      change.restore(ticket, before)
      expect(ticket.reload.custom_attributes['status']).to eq('open')
      expect(change.still_applied?(ticket)).to be(false)
    end

    it 'clears a date and puts it back' do
      change = build({ 'field' => 'due_date', 'clear' => true }).first
      before = change.apply(ticket)
      expect(before).to eq('2026-09-30')
      expect(ticket.reload.custom_attributes).not_to have_key('due_date')
      change.restore(ticket, before)
      expect(ticket.reload.custom_attributes['due_date']).to eq('2026-09-30')
    end

    it 'sets a yes/no' do
      change = build({ 'field' => 'reviewed', 'value' => 'true' }).first
      expect(change.apply(ticket)).to be_nil
      expect(ticket.reload.custom_attributes['reviewed']).to be(true)
      expect(change.still_applied?(ticket)).to be(true)
    end
  end

  describe 'the multi-valued kinds' do
    it 'adds and removes multiselect values and restores the old array' do
      change = build({ 'field' => 'component', 'add' => ['api'], 'remove' => ['web'] }).first
      before = change.apply(ticket)
      expect(before).to eq(['web'])
      expect(ticket.reload.custom_attributes['component']).to eq(['api'])
      expect(change.still_applied?(ticket)).to be(true)
      change.restore(ticket, before)
      expect(ticket.reload.custom_attributes['component']).to eq(['web'])
    end

    it 'adds and removes tags by name' do
      ticket.tag_list = ['doku']
      change = build({ 'field' => 'tags', 'add' => ['backend'], 'remove' => ['doku'] }).first
      before = change.apply(ticket)
      expect(before).to eq(['doku'])
      expect(ticket.reload.tag_list).to eq(['backend'])
      change.restore(ticket, before)
      expect(ticket.reload.tag_list).to eq(['doku'])
    end

    it 'adds a tag nobody has made yet: the run creates it in the project\'s organisation' do
      change = build({ 'field' => 'tags', 'add' => ['  Kunde-X '] }).first
      expect(change.add).to eq(['kunde-x'])
      expect(change.describe).to eq('Tags: +kunde-x')

      expect { change.apply(ticket) }.to change { Tag.where(name: 'kunde-x', organisation: organisation).count }.from(0).to(1)
      expect(ticket.reload.tag_list).to eq(['kunde-x'])
      expect(change.still_applied?(ticket)).to be(true)
      change.restore(ticket, [])
      expect(ticket.reload.tag_list).to be_empty
    end

    it 'meets an existing tag however it is typed, and never makes a second one' do
      change = build({ 'field' => 'tags', 'add' => ['Backend'] }).first

      expect { change.apply(ticket) }.not_to change(Tag, :count)
      expect(ticket.reload.tag_list).to eq(['backend'])
    end

    it 'refuses a new name that is too long or carries a comma, and a removal of a tag nobody has' do
      longest = 'a' * Tag::MAX_NAME_LENGTH
      expect(build({ 'field' => 'tags', 'add' => [longest] }).first.add).to eq([longest])

      ["#{longest}b", 'kunde,x'].each do |name|
        expect { build({ 'field' => 'tags', 'add' => [name] }) }
          .to raise_error(Tickets::Changes::Invalid) { |e| expect(e.code).to eq(:tag_name_invalid) }
      end
      expect { build({ 'field' => 'tags', 'add' => ['   '] }) }
        .to raise_error(Tickets::Changes::Invalid) { |e| expect(e.code).to eq(:nothing_to_change) }
      expect { build({ 'field' => 'tags', 'remove' => ['gibt-es-nicht'] }) }
        .to raise_error(Tickets::Changes::Invalid) { |e| expect(e.code).to eq(:value_not_allowed) }
    end

    # The limit is for NEW names only: a tag made before the limit existed
    # stays usable, in both directions.
    it 'adds and removes an existing tag whose name is longer than the limit' do
      legacy = create(:tag, name: 'l' * (Tag::MAX_NAME_LENGTH + 5), organisation: organisation).name

      change = build({ 'field' => 'tags', 'add' => [legacy] }).first
      change.apply(ticket)
      expect(ticket.reload.tag_list).to eq([legacy])
      build({ 'field' => 'tags', 'remove' => [legacy] }).first.apply(ticket)
      expect(ticket.reload.tag_list).to be_empty
    end

    it 'removes a tag however it is typed' do
      ticket.tag_list = ['backend']
      build({ 'field' => 'tags', 'remove' => ['  Backend '] }).first.apply(ticket)

      expect(ticket.reload.tag_list).to be_empty
    end

    it 'lets a plus win over a minus of the same name, in any spelling' do
      change = build({ 'field' => 'tags', 'add' => ['doku'], 'remove' => ['Doku'] }).first

      expect(change.remove).to be_empty
      change.apply(ticket)
      expect(ticket.reload.tag_list).to eq(['doku'])
    end

    it 'creates the new tag in the ticket\'s organisation, even when another organisation has the name' do
      stranger = create(:organisation)
      foreign = ActsAsTenant.with_tenant(stranger) { create(:tag, name: 'kunde-x', organisation: stranger) }

      build({ 'field' => 'tags', 'add' => ['kunde-x'] }).first.apply(ticket)

      expect(ticket.reload.tags.map(&:organisation_id)).to eq([organisation.id])
      expect(ticket.tags.map(&:id)).not_to include(foreign.id)
    end

    # The catalogue is the reader's (TagPolicy::Scope): a tag used only in a
    # project the reader cannot open is not offered, cannot be removed by
    # name, and typed as a new name meets the existing record.
    context 'for a member who cannot open every project' do
      let(:reader) { create(:user) }
      let(:catalogue) { Tickets::BulkFields.for(project: project, user: reader, locale: :de) }

      before do
        create(:membership, user: reader, organisation: organisation, active: true,
                            role: create(:role, organisation: organisation, title: 'Member', is_default: true))
        create(:project_permission, user: reader, project: project, tickets_access: 'read_write')
        hidden = create(:project, organisation: organisation)
        create(:tagging, tag: create(:tag, name: 'geheim', organisation: organisation),
                         taggable: create(:ticket, project: hidden, organisation: organisation))
      end

      it 'refuses to remove the hidden tag and never makes it a second time' do
        expect { build({ 'field' => 'tags', 'remove' => ['geheim'] }) }
          .to raise_error(Tickets::Changes::Invalid) { |e| expect(e.code).to eq(:value_not_allowed) }

        expect { build({ 'field' => 'tags', 'add' => ['geheim'] }).first.apply(ticket) }.not_to change(Tag, :count)
        expect(ticket.reload.tag_list).to eq(['geheim'])
      end
    end

    it 'adds and removes assignees through the sync, and refuses a person the ticket cannot take' do
      change = build({ 'field' => 'assignees', 'add' => [member.id] }).first
      before = change.apply(ticket)
      expect(before).to eq([])
      expect(ticket.reload.assignees).to eq([member])
      expect(change.still_applied?(ticket)).to be(true)
      change.restore(ticket, before)
      expect(ticket.reload.assignees).to be_empty

      allow(ticket).to receive(:assignable_user_ids).and_return([])
      expect { change.apply(ticket) }.to raise_error(Tickets::Changes::NotApplicable) { |e| expect(e.code).to eq(:user_not_assignable) }
    end

    it 'adds a watcher as a manual subscription and removes only manual ones' do
      NotificationSubscription.system_subscribe(user: member, item: ticket, source: NotificationSubscription::SOURCE_ASSIGNEE)
      change = build({ 'field' => 'watchers', 'remove' => [member.id] }).first
      before = change.apply(ticket)
      expect(before).to include(member.id.to_s)
      expect(NotificationSubscription.where(subscribable: ticket, user: member, mode: :follow)).to exist, 'an assignee subscription is left alone'

      add = begin
        build({ 'field' => 'watchers', 'add' => [outsider.id] }).first
      rescue StandardError
        nil
      end
      expect(add).to be_nil, 'someone without access is not offered'
    end
  end
end
