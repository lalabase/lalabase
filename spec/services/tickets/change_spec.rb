# frozen_string_literal: true

require 'rails_helper'

# What: Tickets::Change, the one rule of a ticket change through a token: the MCP
#       tool update_ticket and POST /api/v1/tickets/:id/changes (REST R3b).
# Type: service spec. The tool's answers stay pinned in update_ticket_spec.rb and
#       the wire in the request specs; here is what each surface takes from the
#       rule: the refusal of an input and how a write ended, both named, never
#       worded.
# Why:  The rule moved out of the tool so the two surfaces cannot drift apart.
#       Pinned here: a person removed who was not named, a person who may not be
#       assigned passed over, another JSONB key written, a ticket that moved or
#       was deleted changed or built anew, an actor's exception text handed on.
#
# Not tagged :bulk_edit, so Prosopite scans every example here: one write of each
# kind runs below without draining jobs.
RSpec.describe Tickets::Change, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user) }
  let(:colleague) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) do
    bulk_ticket({ 'status' => 'open', 'priority' => 'high', 'area' => 'backend' }, title: 'Login bricht ab')
  end

  before do
    bulk_project_setup
    bulk_member(colleague)
  end
  after { ActsAsTenant.current_tenant = nil }

  def parse(fields = {}, beside: [], **more)
    described_class.parse(fields.merge(more), actor: writer, beside: beside)
  end

  def write(fields, on: ticket, project_of: project)
    parse(fields).write(ticket: on, project: project_of)
  end

  def assignees_of(record)
    record.reload.ticket_assignments.pluck(:user_id)
  end

  def actor_failure(code, errors: ['PG::Error: secret detail'], resource: nil)
    Actors::BaseActor::Result.new(success: false, errors: errors, code: code, resource: resource)
  end

  def broken = "x\xFF".dup.force_encoding('UTF-8')

  describe '.parse' do
    it 'reads a change of each kind' do
      expect(parse(title: 'Neu')).to have_attributes(refused?: false, unreadable?: false, kind: :title)
      expect(parse(status: 'wip')).to have_attributes(refused?: false, kind: :status)
      expect(parse(add_assignee_ids: ['me'])).to have_attributes(refused?: false, kind: :assignees)
      expect(parse(remove_assignee_ids: ['me'])).to have_attributes(refused?: false, kind: :assignees)
      expect(parse(add_assignee_ids: ['me'], remove_assignee_ids: [colleague.id])).to have_attributes(refused?: false)
    end

    # The two surfaces hand their keys over in their own form.
    it 'reads string keys like symbols' do
      expect(parse('status' => 'wip')).to have_attributes(refused?: false, kind: :status)
      expect(parse(ActiveSupport::HashWithIndifferentAccess.new(status: 'wip'))).to have_attributes(refused?: false, kind: :status)
    end

    describe 'the keys' do
      it 'refuses a key it does not know, not ignores it, and hands it to the caller' do
        change = parse(title: 'Neu', priority: 'low')
        expect(change).to have_attributes(refusal: :unknown_keys, refused?: true, unreadable?: true)
        expect(change.refusal_details).to eq(keys: [:priority])
      end

      it 'takes what the caller reads itself as no unknown key, and as no kind' do
        expect(parse({ ticket_id: 'x', status: 'wip' }, beside: %i[ticket_id])).to have_attributes(refused?: false, kind: :status)
        expect(parse({ ticket_id: 'x' }, beside: %i[ticket_id]).refusal).to eq(:one_kind)
      end

      it 'refuses that key without the caller naming it' do
        expect(parse(ticket_id: 'x', status: 'wip').refusal).to eq(:unknown_keys)
      end

      # Rack hands a form key on as it came; Symbol#to_sym cannot hold these bytes.
      it 'refuses a key of invalid bytes instead of crashing on it' do
        expect(parse(broken => 1, 'status' => 'wip').refusal).to eq(:unknown_keys)
      end
    end

    describe 'the encoding' do
      # Refused for every field, before any string method runs on them: strip
      # and the title's patterns raise on these.
      {
        'bytes that are no UTF-8' => -> { broken },
        'a part in Latin-1' => -> { "\xE4x".dup.force_encoding('ISO-8859-1') },
        'a part in UTF-16' => -> { 'ab'.encode('UTF-16LE').force_encoding('UTF-16') },
        'a binary part' => -> { "\xC3\xA4".b }
      }.each do |label, text|
        it "refuses #{label} as a title, a status and a list entry" do
          value = instance_exec(&text)
          [{ title: value }, { status: value }, { add_assignee_ids: [value] }, { remove_assignee_ids: ['me', value] }].each do |fields|
            expect(parse(fields)).to have_attributes(refusal: :invalid_utf8, unreadable?: true)
          end
        end
      end

      it 'checks what the caller reads itself too' do
        expect(parse({ ticket_id: broken, status: 'wip' }, beside: %i[ticket_id])).to have_attributes(refusal: :invalid_utf8)
      end

      it 'answers an unknown key before the bytes' do
        expect(parse(status: broken, priority: 'low').refusal).to eq(:unknown_keys)
      end
    end

    describe 'one kind per change, by which keys are present' do
      {
        'no change' => {},
        'title and status' => { title: 'Neu', status: 'wip' },
        'title and add' => { title: 'Neu', add_assignee_ids: ['me'] },
        'status and remove' => { status: 'wip', remove_assignee_ids: ['me'] },
        'an empty title next to a status' => { title: '', status: 'wip' },
        'a nil title next to a status' => { title: nil, status: 'wip' },
        'an empty list next to a title' => { title: 'Neu', add_assignee_ids: [] }
      }.each do |label, fields|
        it "refuses #{label}" do
          expect(parse(fields)).to have_attributes(refusal: :one_kind, refused?: true, unreadable?: false)
        end
      end

      it 'counts both assignee lists as one kind' do
        expect(parse(add_assignee_ids: ['me'], remove_assignee_ids: [colleague.id]).refused?).to be false
      end
    end

    describe 'the title' do
      limit = Ticket::TITLE_MAX_LENGTH

      {
        'a number' => [5, :title_not_string],
        'nil' => [nil, :title_not_string],
        'a list' => [['Neu'], :title_not_string],
        'a line break' => ["a\nb", :title_forbidden],
        'a NUL byte' => ["a#{0.chr}b", :title_forbidden],
        'an empty text' => ['', :title_empty],
        'spaces alone' => ['   ', :title_empty],
        'a no-break space alone' => [0xA0.chr(Encoding::UTF_8), :title_empty],
        'a text over the limit' => ['a' * (limit + 1), :title_too_long]
      }.each do |label, (value, refusal)|
        it "refuses #{label} as #{refusal}" do
          expect(parse(title: value).refusal).to eq(refusal)
        end
      end

      it 'names the limit a too long title is over' do
        expect(parse(title: 'a' * (limit + 1)).refusal_details).to include(max: limit)
      end

      it 'takes the limit' do
        expect(parse(title: 'a' * limit).refused?).to be false
      end
    end

    describe 'the status' do
      { 'a number' => [5, :status_not_string], 'a list' => [['wip'], :status_not_string], 'nil' => [nil, :status_not_string],
        'spaces alone' => ['  ', :status_empty] }.each do |label, (value, refusal)|
        it "refuses #{label} as #{refusal}" do
          expect(parse(status: value).refusal).to eq(refusal)
        end
      end
    end

    describe 'the assignee lists' do
      %i[add_assignee_ids remove_assignee_ids].each do |key|
        it "refuses #{key} that is no list of texts, naming the list" do
          ['some-uuid', nil, [5], [nil], { id: 'me' }].each do |value|
            change = parse(key => value)
            expect(change.refusal).to eq(:assignees_not_a_list)
            expect(change.refusal_details).to eq(list: key)
          end
        end

        it "refuses an entry of #{key} that is no user id, naming the list" do
          change = parse(key => %w[me oops])
          expect(change.refusal).to eq(:assignee_invalid)
          expect(change.refusal_details).to eq(list: key)
        end
      end

      it 'takes the limit and refuses one more, naming it' do
        at_limit = Array.new(described_class::MAX_ASSIGNEE_IDS) { SecureRandom.uuid }

        expect(parse(add_assignee_ids: at_limit).refused?).to be false
        over = parse(remove_assignee_ids: at_limit + [SecureRandom.uuid])
        expect(over.refusal).to eq(:too_many_assignees)
        expect(over.refusal_details).to eq(max: 50)
      end

      it 'refuses lists that name nobody' do
        expect(parse(add_assignee_ids: []).refusal).to eq(:no_assignees)
        expect(parse(add_assignee_ids: [], remove_assignee_ids: []).refusal).to eq(:no_assignees)
      end

      it 'refuses the same user in both lists, however they are spelled' do
        expect(parse(add_assignee_ids: [colleague.id], remove_assignee_ids: [colleague.id]).refusal).to eq(:assignees_overlap)
        expect(parse(add_assignee_ids: ['me'], remove_assignee_ids: [writer.id]).refusal).to eq(:assignees_overlap)
        expect(parse(add_assignee_ids: [writer.id.delete('-').upcase], remove_assignee_ids: ['me']).refusal).to eq(:assignees_overlap)
      end

      it 'keeps "me" in lower case only' do
        expect(parse(add_assignee_ids: ['ME']).refusal).to eq(:assignee_invalid)
      end
    end

    # REFUSALS is the list the surfaces word; a refusal outside it raises there.
    it 'lists every refusal it answers' do
      source = Rails.root.join('app/services/tickets/change.rb').read
      expect(source.scan(/refuse\(:(\w+)/).flatten.map(&:to_sym) - described_class::REFUSALS).to be_empty
    end
  end

  describe '#write' do
    it 'writes no refused change' do
      expect(Actors::SaveTicket).not_to receive(:call)
      expect { write({ title: '' }) }.to raise_error(ArgumentError, /title_empty/)
    end

    describe 'a status' do
      it 'goes through the board actor and writes only the status key' do
        expect(Actors::ApplyTicketChanges).to receive(:call).once.and_call_original
        outcome = nil
        expect { outcome = write({ status: ' wip ' }) }.to change(TicketBulkRun, :count).by(1)

        expect(outcome).to have_attributes(written?: true, gone?: false, unexpected?: false, failure: nil)
        expect(ticket.reload.custom_attributes).to eq('status' => 'wip', 'priority' => 'high', 'area' => 'backend')
      end

      # Keys come from the project; compared as they are, spelled by the project.
      it 'refuses a value outside the project catalogue, writing nothing' do
        ticket
        outcome = nil
        expect { outcome = write({ status: 'WIP' }) }.not_to change(TicketBulkRun, :count)

        expect(outcome).to have_attributes(written?: false, failure: :status_not_allowed, reason: :value_not_allowed, messages: [])
        expect(ticket.reload.custom_attributes['status']).to eq('open')
      end

      context 'in a project without a status field' do
        let(:bare_project) { create(:project, organisation: organisation) }
        let(:bare_ticket) { create(:ticket, project: bare_project, organisation: organisation, creator: writer, title: 'Ohne Status') }

        def status_write
          write({ status: 'wip' }, on: bare_ticket, project_of: bare_project)
        end

        it 'is refused before any actor runs' do
          expect(Actors::ApplyTicketChanges).not_to receive(:call)
          expect(status_write).to have_attributes(failure: :no_status_field, reason: :no_status_field)
        end

        # The board writes any active field named "status"; the rule's status is
        # the select list_tickets reads its keys from.
        { 'multiselect' => 'wip', 'checkbox' => 'true', 'date' => '2026-10-09' }.each do |field_type, value|
          it "stays refused when \"status\" is a #{field_type}" do
            create(:ticket_attribute_definition, project: bare_project, name: 'status', field_type: field_type, position: 1,
                                                 labels: { 'de' => 'Status', 'en' => 'Status' },
                                                 options: { 'allowed_values' => [{ 'value' => 'wip', 'labels' => { 'de' => 'wip' } }] })
            before = bare_ticket.reload.custom_attributes

            outcome = write({ status: value }, on: bare_ticket, project_of: bare_project)

            expect(outcome.failure).to eq(:no_status_field)
            expect(bare_ticket.reload.custom_attributes).to eq(before)
          end
        end

        it 'stays refused when the status select is switched off' do
          create(:ticket_attribute_definition, project: bare_project, name: 'status', field_type: 'select', position: 1,
                                               active: false, labels: { 'de' => 'Status', 'en' => 'Status' },
                                               options: { 'allowed_values' => [{ 'value' => 'wip', 'labels' => { 'de' => 'wip' } }] })
          expect(status_write.failure).to eq(:no_status_field)
        end

        %i[unknown_field nothing_to_change unknown_kind].each do |code|
          it "reads the actor's #{code} as no status field" do
            create(:ticket_attribute_definition, project: bare_project, name: 'status', field_type: 'select', position: 1,
                                                 labels: { 'de' => 'Status', 'en' => 'Status' },
                                                 options: { 'allowed_values' => [{ 'value' => 'wip', 'labels' => { 'de' => 'wip' } }] })
            allow(Actors::ApplyTicketChanges).to receive(:call).and_return(actor_failure(code))

            expect(status_write.failure).to eq(:no_status_field)
          end
        end
      end

      # Only a title hands on what the model said: for a field the actor has a
      # generic board text, whatever its record holds.
      it 'reads a save the model refuses as a ticket not saved, without any messages' do
        run = TicketBulkRun.new.tap { |record| record.errors.add(:base, 'Kartentext') }
        allow(Actors::ApplyTicketChanges).to receive(:call)
          .and_return(actor_failure(:validation_failed, errors: ['Kartentext'], resource: run))

        expect(write({ status: 'wip' })).to have_attributes(failure: :ticket_not_saved, reason: :validation_failed, messages: [])
      end
    end

    describe 'assignees' do
      it 'adds "me" against the current list, keeping the people on it' do
        ticket.assignees << colleague

        expect(write({ add_assignee_ids: ['me'] })).to be_written
        expect(assignees_of(ticket)).to contain_exactly(colleague.id, writer.id)
      end

      it 'removes only who is named' do
        ticket.assignees << colleague
        ticket.assignees << writer

        expect(write({ remove_assignee_ids: [colleague.id] })).to be_written
        expect(assignees_of(ticket)).to eq([writer.id])
      end

      it 'reads the list under the actor, not from the ticket the caller holds' do
        held = Ticket.find(ticket.id)
        held.assignees.load
        ticket.assignees << colleague

        expect(write({ add_assignee_ids: ['me'] }, on: held)).to be_written
        expect(assignees_of(ticket)).to contain_exactly(colleague.id, writer.id)
      end

      it 'refuses a person the project does not offer, and takes nobody off' do
        ticket.assignees << colleague
        outcome = write({ add_assignee_ids: [SecureRandom.uuid], remove_assignee_ids: [colleague.id] })

        expect(outcome).to have_attributes(failure: :assignee_not_allowed, reason: :value_not_allowed)
        expect(assignees_of(ticket)).to eq([colleague.id])
      end

      it 'refuses a person who lost access meanwhile, and takes nobody off' do
        ticket.assignees << colleague
        allow_any_instance_of(Ticket).to receive(:assignable_user_ids).and_return([])

        outcome = write({ add_assignee_ids: ['me'], remove_assignee_ids: [colleague.id] })

        expect(outcome).to have_attributes(failure: :user_not_assignable, reason: :user_not_assignable)
        expect(assignees_of(ticket)).to eq([colleague.id])
      end

      it 'keeps a stale assignee who is not named' do
        stale = create(:user)
        create(:membership, user: stale, organisation: organisation, role: create(:role, organisation: organisation))
        ticket.ticket_assignments.create!(user: stale)

        expect(write({ add_assignee_ids: ['me'] })).to be_written
        expect(assignees_of(ticket)).to contain_exactly(stale.id, writer.id)
      end
    end

    describe 'a title' do
      before { ticket.assignees << colleague }

      it 'goes through SaveTicket alone, with the title alone' do
        expect(Actors::SaveTicket).to receive(:call)
          .with(project: project, params: { title: 'Neu' }, id: ticket.id, current_user: writer).and_call_original
        expect(Actors::ApplyTicketChanges).not_to receive(:call)

        expect(write({ title: '  Neu  ' })).to be_written
        expect(ticket.reload).to have_attributes(title: 'Neu', assignees: [colleague],
                                                 custom_attributes: { 'status' => 'open', 'priority' => 'high', 'area' => 'backend' })
      end

      it 'names the caller in the history, also without an ambient Current.user' do
        Current.reset

        expect { write({ title: 'Neu' }) }.to change { Activity.where(trackable: ticket, key: 'ticket.title_changed', actor: writer).count }.by(1)
        expect(Current.user).to be_nil
      end

      it 'hands on the messages of a title the model refuses' do
        ticket.update_column(:number, nil)

        outcome = I18n.with_locale(:en) { write({ title: 'Neu' }) }

        expect(outcome).to have_attributes(failure: :title_not_saved, reason: :validation_failed)
        expect(I18n.with_locale(:en) { outcome.messages }).to eq(["Number can't be blank"])
        expect(I18n.with_locale(:de) { outcome.messages }).to eq(['Nummer darf nicht leer sein'])
        expect(ticket.reload.title).to eq('Login bricht ab')
      end

      it 'locks the ticket in this project and writes inside that transaction' do
        ticket
        statements = []
        depth_at_write = nil
        outer_depth = ActiveRecord::Base.connection.open_transactions
        allow(Actors::SaveTicket).to receive(:call).and_wrap_original do |original, **kwargs|
          depth_at_write = ActiveRecord::Base.connection.open_transactions
          original.call(**kwargs)
        end
        collect = ->(*, payload) { statements << payload[:sql] }

        ActiveSupport::Notifications.subscribed(collect, 'sql.active_record') { write({ title: 'Neu' }) }

        lock = statements.find { |sql| sql.include?('FROM "tickets"') && sql.include?('FOR UPDATE') }
        expect(lock).to include('"tickets"."project_id"')
        expect(depth_at_write).to be > outer_depth
      end
    end

    # After the caller's lookup: SaveTicket finds a ticket organisation-wide and
    # builds a new one for an id it does not find.
    describe 'a ticket that left after the lookup' do
      let(:elsewhere) { create(:project, organisation: organisation) }

      it 'keeps a moved ticket from being renamed there' do
        ticket
        Ticket.where(id: ticket.id).update_all(project_id: elsewhere.id)

        expect(write({ title: 'Gekapert' })).to have_attributes(gone?: true, written?: false, unexpected?: false)
        expect(ticket.reload.title).to eq('Login bricht ab')
      end

      it 'builds no ticket for a deleted one' do
        ticket
        Ticket.where(id: ticket.id).delete_all

        expect(write({ title: 'Phantom' })).to be_gone
        expect(Ticket.where(title: 'Phantom')).not_to exist
      end

      it 'answers a moved ticket as gone for a status too' do
        ticket
        Ticket.where(id: ticket.id).update_all(project_id: elsewhere.id)

        expect(write({ status: 'wip' })).to be_gone
        expect(ticket.reload.custom_attributes['status']).to eq('open')
      end

      it "reads the actor's outside_scope as gone" do
        allow(Actors::ApplyTicketChanges).to receive(:call).and_return(actor_failure(:outside_scope))

        expect(write({ status: 'wip' })).to be_gone
      end
    end

    describe 'a failure the rule does not name' do
      %i[internal_error stale_object not_member stock_changed].each do |code|
        it "is unexpected for #{code}, and hands on no text" do
          allow(Actors::ApplyTicketChanges).to receive(:call).and_return(actor_failure(code))
          outcome = write({ status: 'wip' })

          expect(outcome).to have_attributes(written?: false, unexpected?: true, messages: [])
        end
      end

      it 'is unexpected for SaveTicket as well' do
        allow(Actors::SaveTicket).to receive(:call).and_return(actor_failure(:internal_error, resource: ticket))

        expect(write({ title: 'Neu' })).to have_attributes(unexpected?: true, messages: [])
      end

      # On a title or an assignee list the codes of a missing status field mean
      # something else, and the rule does not read them as that.
      it 'is unexpected for an unknown field on an assignee change' do
        allow(Actors::ApplyTicketChanges).to receive(:call).and_return(actor_failure(:unknown_field))

        expect(write({ add_assignee_ids: ['me'] })).to be_unexpected
      end
    end
  end

  describe 'the lists a caller words' do
    it 'names every failure once, each with a reason a client reads' do
      expect(described_class::REASONS.values.uniq)
        .to contain_exactly(:value_not_allowed, :user_not_assignable, :no_status_field, :validation_failed)
      expect(described_class::FAILURES).to eq(described_class::REASONS.keys)
    end
  end
end
