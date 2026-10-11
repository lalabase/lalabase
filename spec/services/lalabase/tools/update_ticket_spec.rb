# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::UpdateTicket, the MCP write for status, assignees and
#   title (terminal client S2, lalabase-private doc/terminal_client_s2_update_ticket_plan.md).
# Type: service spec, through #execute (no schema check in front, so every
#   argument shape reaches the tool).
# Why: the tool adds no write path of its own. Status and assignees go through
#   Actors::ApplyTicketChanges like the board and the head menu, the title through
#   Actors::SaveTicket without assignee_ids. "Assign to me" adds and removes nobody,
#   a status change keeps every other attribute, and exactly one kind of change is
#   allowed per call, decided by which keys are present.
#
# Not tagged :bulk_edit, so Prosopite scans every example here: one write of each
# kind runs below without draining jobs.
RSpec.describe Lalabase::Tools::UpdateTicket do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user, first_name: 'Willi', last_name: 'Writer') }
  let(:colleague) { create(:user, first_name: 'Anna', last_name: 'Berg') }
  let(:project) { create(:project, organisation: organisation) }
  let(:recorder) { Lalabase::Tools::AuthorizationRecorder.new }
  let(:context) do
    Lalabase::Tools::Context.new(actor: writer, organisation: organisation, project: project, authorization: recorder)
  end
  let(:ticket) do
    bulk_ticket({ 'status' => 'open', 'priority' => 'high', 'area' => 'backend' }, title: 'Login bricht ab')
  end

  before do
    bulk_project_setup
    bulk_member(colleague)
  end
  after { ActsAsTenant.current_tenant = nil }

  def run(args)
    described_class.execute(args: { ticket_id: ticket.id }.merge(args), context: context)
  end

  def assignee_ids_of(record)
    record.reload.ticket_assignments.pluck(:user_id)
  end

  # A user with a plain role and no project permission: in the organisation, not
  # in this project.
  def outsider
    @outsider ||= create(:user).tap do |user|
      create(:membership, user: user, organisation: organisation,
                          role: create(:role, organisation: organisation))
    end
  end

  # Snapshot of what any write could touch.
  def state_of(record)
    record.reload
    [record.title, record.custom_attributes, record.ticket_assignments.pluck(:user_id).sort,
     record.content.to_plain_text, TicketBulkRun.count, Activity.count]
  end

  describe 'contract metadata' do
    it 'is a project-scoped, mutating, record-mode tool that requires the actor' do
      expect(described_class.tool_name).to eq('update_ticket')
      expect(described_class.scope_mode).to eq(:project)
      expect(described_class.mutating?).to be true
      expect(described_class.requires_actor?).to be true
      expect(described_class.authorization_mode).to eq(:record)
    end

    it 'declares a flat schema: ticket_id required, the four changes optional' do
      schema = described_class.input_schema
      expect(schema[:properties].keys).to contain_exactly(:ticket_id, :title, :status, :add_assignee_ids,
                                                          :remove_assignee_ids)
      expect(schema[:required]).to eq(%w[ticket_id])
      expect(schema.keys & %i[oneOf anyOf allOf]).to be_empty
    end
  end

  describe 'exactly one kind of change per call (by key, not by value)' do
    mixed_calls = {
      'title and status' => { title: 'Neu', status: 'wip' },
      'title and add' => { title: 'Neu', add_assignee_ids: ['me'] },
      'status and remove' => { status: 'wip', remove_assignee_ids: ['me'] },
      'all three' => { title: 'Neu', status: 'wip', add_assignee_ids: ['me'] },
      'an empty title next to a status' => { title: '', status: 'wip' },
      'a nil title next to a status' => { title: nil, status: 'wip' },
      'an empty add list next to a title' => { title: 'Neu', add_assignee_ids: [] }
    }

    mixed_calls.each do |label, args|
      it "refuses #{label} as invalid_input and writes nothing" do
        before = state_of(ticket)
        result = run(args)

        expect(result.error_code).to eq(:invalid_input)
        expect(result.error).to eq('exactly one change per call: title, status, or add_assignee_ids/remove_assignee_ids')
        expect(state_of(ticket)).to eq(before)
      end
    end

    it 'refuses a call without any change' do
      result = run({})
      expect(result.error_code).to eq(:invalid_input)
      expect(result.error).to match(/exactly one change per call/)
    end

    # A guessed argument (a priority, a replace-all assignee list) must not
    # read as done: the answer would say ok while only the title changed.
    it 'refuses an argument it does not know, naming it, and writes nothing' do
      before = state_of(ticket)
      result = run(title: 'Neu', priority: 'low', assignee_ids: [writer.id])

      expect(result.error_code).to eq(:invalid_input)
      expect(result.error).to eq('unknown arguments: assignee_ids, priority')
      expect(state_of(ticket)).to eq(before)
    end

    # The answer is printed by a client; a key is caller text like any value.
    it 'names an unknown argument only when its name is plain' do
      result = run(:title => 'Neu', :priority => 'low', "x#{27.chr}[2J\nevil" => 1)

      expect(result.error).to eq('unknown arguments: priority, 1 not shown')
    end

    it 'counts an unknown argument with a very long name instead of repeating it' do
      expect(run(:title => 'Neu', ('a' * 64) => 1).error).to eq("unknown arguments: #{'a' * 64}")
      expect(run(:title => 'Neu', ('a' * 65) => 1).error).to eq('unknown arguments: 1 not shown')
    end
  end

  describe 'input shapes, refused before any lookup' do
    shapes = [
      [{ ticket_id: nil, status: 'wip' }, 'ticket_id is required'],
      [{ ticket_id: 'oops', status: 'wip' }, 'invalid ticket_id format'],
      [{ title: 5 }, 'title must be a string'],
      [{ title: '   ' }, 'title is required'],
      [{ status: ['wip'] }, 'status must be a string'],
      [{ status: ' ' }, 'status is required'],
      [{ add_assignee_ids: 'some-uuid' }, 'add_assignee_ids must be a list of user UUIDs or "me"'],
      [{ remove_assignee_ids: [5] }, 'remove_assignee_ids must be a list of user UUIDs or "me"'],
      [{ add_assignee_ids: ['oops'] }, 'invalid user id in add_assignee_ids'],
      [{ remove_assignee_ids: %w[me oops] }, 'invalid user id in remove_assignee_ids'],
      [{ add_assignee_ids: [], remove_assignee_ids: [] }, 'add_assignee_ids or remove_assignee_ids must name at least one user'],
      [{ add_assignee_ids: [] }, 'add_assignee_ids or remove_assignee_ids must name at least one user'],
      [{ add_assignee_ids: nil }, 'add_assignee_ids must be a list of user UUIDs or "me"'],
      [{ add_assignee_ids: ['ME'] }, 'invalid user id in add_assignee_ids'],
      [{ title: "Neu\xFF".dup.force_encoding('UTF-8') }, 'arguments must be valid UTF-8'],
      [{ status: "wip\xFF".dup.force_encoding('UTF-8') }, 'arguments must be valid UTF-8'],
      [{ add_assignee_ids: ["me\xFF".dup.force_encoding('UTF-8')] }, 'arguments must be valid UTF-8']
    ]

    shapes.each do |args, text|
      it "#{args.inspect}: #{text}" do
        before = state_of(ticket)
        result = run(args)

        expect(result.error_code).to eq(:invalid_input)
        expect(result.error).to eq(text)
        expect(state_of(ticket)).to eq(before)
      end
    end

    it 'refuses the same user in both lists, also when one of them says "me"' do
      before = state_of(ticket)
      both = run(add_assignee_ids: [colleague.id], remove_assignee_ids: [colleague.id])
      me = run(add_assignee_ids: ['me'], remove_assignee_ids: [writer.id])

      expect([both.error_code, me.error_code]).to all(eq(:invalid_input))
      expect([both.error, me.error]).to all(eq('add_assignee_ids and remove_assignee_ids name the same user'))
      expect(state_of(ticket)).to eq(before)
    end

    it 'takes 50 ids in a list and refuses 51' do
      at_limit = Array.new(described_class::MAX_ASSIGNEE_IDS) { SecureRandom.uuid }
      over = at_limit + [SecureRandom.uuid]

      expect(run(add_assignee_ids: over).error).to eq('at most 50 user ids per list')
      # At the limit the shape passes; these random people are then refused by the project.
      expect(run(add_assignee_ids: at_limit).reason).to eq(:value_not_allowed)
    end

    # The spellings Postgres accepts for a uuid name the same person.
    it 'takes a user id in capitals, without dashes or with spaces around it' do
      ticket.assignees << colleague
      undashed = colleague.id.delete('-')

      expect(run(remove_assignee_ids: [undashed.upcase]).success?).to be true
      expect(assignee_ids_of(ticket)).to be_empty
      expect(run(add_assignee_ids: [" #{colleague.id.upcase} ", ' me ']).success?).to be true
      expect(assignee_ids_of(ticket)).to contain_exactly(colleague.id, writer.id)
    end

    it 'sees "me" and the caller without dashes as the same user' do
      result = run(add_assignee_ids: ['me'], remove_assignee_ids: [writer.id.delete('-')])
      expect(result.error).to eq('add_assignee_ids and remove_assignee_ids name the same user')
    end

    it 'collapses duplicates inside one list' do
      result = run(add_assignee_ids: ['me', writer.id, 'me'])
      expect(result.success?).to be true
      expect(assignee_ids_of(ticket)).to eq([writer.id])
    end
  end

  describe 'status' do
    it 'sets the status through the board actor and keeps every other attribute' do
      expect(Actors::ApplyTicketChanges).to receive(:call).once.and_call_original
      result = nil
      expect { result = run(status: 'wip') }.to change(TicketBulkRun, :count).by(1)

      expect(result.success?).to be true
      expect(ticket.reload.custom_attributes).to eq('status' => 'wip', 'priority' => 'high', 'area' => 'backend')
      expect(JSON.parse(result.content)['status']).to eq('wip')
      expect(recorder.authorized?).to be true
      expect(TicketBulkRun.last.change_list).to eq([{ 'field' => 'status', 'kind' => 'single', 'value' => 'wip' }])
    end

    it 'takes a key with spaces around it' do
      expect(run(status: ' wip ').success?).to be true
      expect(ticket.reload.custom_attributes['status']).to eq('wip')
    end

    # The value is not echoed: a client prints the answer, and the value is
    # whatever the caller (an agent, say) sent, control characters included.
    ['erledigt', 'in Arbeit', 'WIP', "x#{27.chr}[31mROT\nzwei"].each do |value|
      it "refuses #{value.inspect} (not a key of this project) as refused/value_not_allowed, no run" do
        before = state_of(ticket)
        result = run(status: value)

        expect(result.error_code).to eq(:refused)
        expect(result.reason).to eq(:value_not_allowed)
        expect(result.error).to eq('status is not a status of this project; use a key from meta.available_statuses')
        expect(state_of(ticket)).to eq(before)
      end
    end

    context 'in a project without a status field' do
      let(:bare_project) { create(:project, organisation: organisation) }
      let(:context) do
        Lalabase::Tools::Context.new(actor: writer, organisation: organisation, project: bare_project, authorization: recorder)
      end
      let(:ticket) { create(:ticket, project: bare_project, organisation: organisation, creator: writer, title: 'Ohne Status') }

      it 'refuses as refused/no_status_field' do
        result = run(status: 'wip')
        expect(result.error_code).to eq(:refused)
        expect(result.reason).to eq(:no_status_field)
        expect(result.error).to eq('this project has no status field')
        expect(TicketBulkRun.count).to eq(0)
      end

      it 'refuses as refused/no_status_field when "status" is a multiselect' do
        create(:ticket_attribute_definition, project: bare_project, name: 'status', field_type: 'multiselect',
                                             position: 1, labels: { 'de' => 'Status', 'en' => 'Status' },
                                             options: { 'allowed_values' => [{ 'value' => 'wip', 'labels' => { 'de' => 'wip' } }] })
        result = run(status: 'wip')
        expect(result.reason).to eq(:no_status_field)
      end

      # The board writes any active field named "status"; the tool's contract
      # is the select list_tickets reads its keys from.
      { 'checkbox' => 'true', 'date' => '2026-10-09' }.each do |field_type, value|
        it "refuses as refused/no_status_field when \"status\" is a #{field_type}, writing nothing" do
          create(:ticket_attribute_definition, project: bare_project, name: 'status', field_type: field_type,
                                               position: 1, labels: { 'de' => 'Status', 'en' => 'Status' }, options: {})
          before = state_of(ticket)

          result = run(status: value)

          expect(result.reason).to eq(:no_status_field)
          expect(state_of(ticket)).to eq(before)
        end
      end

      it 'refuses as refused/no_status_field when the status select is switched off' do
        create(:ticket_attribute_definition, project: bare_project, name: 'status', field_type: 'select', position: 1,
                                             active: false, labels: { 'de' => 'Status', 'en' => 'Status' },
                                             options: { 'allowed_values' => [{ 'value' => 'wip', 'labels' => { 'de' => 'wip' } }] })
        expect(run(status: 'wip').reason).to eq(:no_status_field)
      end
    end

    # A save the model refuses, not a bad request. The bulk actor's own text is
    # a German board sentence; the MCP answer is English.
    it 'answers a status save the model refuses as refused/validation_failed in English' do
      ticket
      allow_any_instance_of(Ticket).to receive(:valid?).and_wrap_original do |original, *args|
        record = original.receiver
        next original.call(*args) unless record.custom_attributes_changed?

        record.errors.add(:base, :invalid)
        false
      end
      before = state_of(ticket)

      result = run(status: 'wip')

      expect(result.error_code).to eq(:refused)
      expect(result.reason).to eq(:validation_failed)
      expect(result.error).to eq('the ticket could not be saved')
      expect(state_of(ticket)).to eq(before)
    end
  end

  describe 'assignees' do
    it '"me" adds the caller and keeps the colleague already assigned' do
      ticket.assignees << colleague
      expect(Actors::ApplyTicketChanges).to receive(:call).once.and_call_original
      result = nil
      expect { result = run(add_assignee_ids: ['me']) }.to change(TicketBulkRun, :count).by(1)

      expect(result.success?).to be true
      expect(assignee_ids_of(ticket)).to contain_exactly(colleague.id, writer.id)
      expect(JSON.parse(result.content)['assignees'].pluck('id')).to contain_exactly(colleague.id, writer.id)
      expect(ticket.custom_attributes).to eq('status' => 'open', 'priority' => 'high', 'area' => 'backend')
    end

    it 'removing one person keeps the others' do
      ticket.assignees << colleague
      ticket.assignees << writer

      result = run(remove_assignee_ids: [colleague.id])

      expect(result.success?).to be true
      expect(assignee_ids_of(ticket)).to eq([writer.id])
    end

    it 'adds and removes in one change' do
      ticket.assignees << colleague

      result = run(add_assignee_ids: ['me'], remove_assignee_ids: [colleague.id])

      expect(result.success?).to be true
      expect(assignee_ids_of(ticket)).to eq([writer.id])
    end

    # A person assigned while they had access, who lost it since, stays: only
    # the people a change ADDS must be assignable.
    it 'adds the caller beside a stale assignee, who stays' do
      ticket.ticket_assignments.create!(user: outsider)

      result = run(add_assignee_ids: ['me'])

      expect(result.success?).to be true
      expect(assignee_ids_of(ticket)).to contain_exactly(outsider.id, writer.id)
    end

    # The person added lost access after the option list was read.
    it 'refuses with user_not_assignable when an added person lost access in the meantime, changing nothing' do
      before = state_of(ticket)
      allow_any_instance_of(Ticket).to receive(:assignable_user_ids).and_return([])

      result = run(add_assignee_ids: ['me'])

      expect(result.error_code).to eq(:refused)
      expect(result.reason).to eq(:user_not_assignable)
      expect(result.error).to eq('nothing was changed: a person in this change no longer has access to this project')
      expect(state_of(ticket)).to eq(before)
    end

    # A deactivated member keeps every permission row, so the project's access
    # list still names them. Assignable are ACTIVE members only, as in the edit
    # form (Project#assignable_users).
    it 'refuses a deactivated member as value_not_allowed' do
      colleague.memberships.find_by!(organisation: organisation).update!(active: false)
      before = state_of(ticket)

      result = run(add_assignee_ids: [colleague.id])

      expect(result.reason).to eq(:value_not_allowed)
      expect(state_of(ticket)).to eq(before)
    end

    # Plan 9.7: a person assigned while they had access is removable, so the
    # terminal can clear the assignment that blocks "assign to me".
    it 'removes a stale assignee and adds the caller in one change' do
      ticket.ticket_assignments.create!(user: outsider)

      result = run(add_assignee_ids: ['me'], remove_assignee_ids: [outsider.id])

      expect(result.success?).to be true
      expect(assignee_ids_of(ticket)).to eq([writer.id])
    end

    it 'removes a deactivated assignee' do
      ticket.assignees << colleague
      colleague.memberships.find_by!(organisation: organisation).update!(active: false)

      result = run(remove_assignee_ids: [colleague.id])

      expect(result.success?).to be true
      expect(assignee_ids_of(ticket)).to be_empty
    end

    it 'removes the caller with "me"' do
      ticket.assignees << colleague
      ticket.assignees << writer

      expect(run(remove_assignee_ids: ['me']).success?).to be true
      expect(assignee_ids_of(ticket)).to eq([colleague.id])
    end

    it 'answers an assignment the save refuses as refused/validation_failed in English' do
      allow(TicketAssignmentSync).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(Ticket.new))
      result = run(add_assignee_ids: ['me'])

      expect(result.reason).to eq(:validation_failed)
      expect(result.error).to eq('the ticket could not be saved')
      expect(assignee_ids_of(ticket)).to be_empty
    end

    # RemoveMembershipService deletes the membership and leaves the assignment:
    # the person is no member at all any more, and still on the ticket.
    it 'removes an assignee whose membership was deleted' do
      ticket.assignees << colleague
      colleague.memberships.find_by!(organisation: organisation).destroy!

      result = run(remove_assignee_ids: [colleague.id])

      expect(result.success?).to be true
      expect(assignee_ids_of(ticket)).to be_empty
    end

    # The assignment alone, without the subscription that usually comes with it:
    # the assignment is what makes the person removable.
    it 'removes an assignee whose membership was deleted and who follows nothing' do
      ticket.assignees << colleague
      NotificationSubscription.where(user: colleague).delete_all
      colleague.memberships.find_by!(organisation: organisation).destroy!

      expect(run(remove_assignee_ids: [colleague.id]).success?).to be true
      expect(assignee_ids_of(ticket)).to be_empty
    end

    it 'still refuses to remove a user of another organisation' do
      stranger = create(:user)
      other_organisation = create(:organisation)
      ActsAsTenant.with_tenant(other_organisation) do
        create(:membership, user: stranger, organisation: other_organisation,
                            role: create(:admin_role, organisation: other_organisation))
      end

      result = run(remove_assignee_ids: [stranger.id])

      expect(result.reason).to eq(:value_not_allowed)
    end

    # Three people the project does not offer, one example each (one actor call
    # per example keeps Prosopite meaningful). The text is the same for all three,
    # so the answer tells no existence.
    {
      'an unknown user' => -> { SecureRandom.uuid },
      'a user of another organisation' => lambda {
        stranger = create(:user)
        other_organisation = create(:organisation)
        ActsAsTenant.with_tenant(other_organisation) do
          create(:membership, user: stranger, organisation: other_organisation,
                              role: create(:admin_role, organisation: other_organisation))
        end
        stranger.id
      },
      'a member without access to the project' => -> { outsider.id }
    }.each do |label, user_id|
      it "answers #{label} as refused/value_not_allowed with the shared text" do
        id = instance_exec(&user_id)
        before = state_of(ticket)
        result = run(add_assignee_ids: [id])

        expect(result.error_code).to eq(:refused)
        expect(result.reason).to eq(:value_not_allowed)
        expect(result.error).to eq('a user in this change cannot be assigned in this project')
        expect(state_of(ticket)).to eq(before)
      end
    end
  end

  describe 'title' do
    before do
      ticket.assignees << colleague
      ticket.update!(content: 'Nach dem Absenden bleibt die Seite weiß.')
    end

    it 'changes the title alone, through SaveTicket without assignee_ids' do
      expect(Actors::SaveTicket).to receive(:call)
        .with(project: project, params: { title: 'Login bricht in Safari ab' }, id: ticket.id, current_user: writer)
        .and_call_original
      expect(Actors::ApplyTicketChanges).not_to receive(:call)
      result = nil
      expect { result = run(title: '  Login bricht in Safari ab  ') }.not_to change(TicketBulkRun, :count)

      expect(result.success?).to be true
      ticket.reload
      expect(ticket.title).to eq('Login bricht in Safari ab')
      expect(ticket.assignees).to contain_exactly(colleague)
      expect(ticket.custom_attributes).to eq('status' => 'open', 'priority' => 'high', 'area' => 'backend')
      expect(ticket.content.to_plain_text).to eq('Nach dem Absenden bleibt die Seite weiß.')
      expect(JSON.parse(result.content)['title']).to eq('Login bricht in Safari ab')
    end

    # The title activity is written on commit and names Current.user. The lock's
    # transaction commits after SaveTicket restored Current.user, so a caller
    # without one of its own (a job, a service; MCP over HTTP sets it from the
    # token) wrote the title without a word in the history.
    it 'records the rename as the caller, also without an ambient Current.user' do
      ticket
      Current.reset

      expect { run(title: 'Login bricht in Safari ab') }
        .to change { Activity.where(trackable: ticket, key: 'ticket.title_changed', actor: writer).count }.by(1)
      expect(Current.user).to be_nil
    end

    it 'takes 255 characters and refuses 256' do
      limit = Ticket::TITLE_MAX_LENGTH
      expect(run(title: 'a' * (limit + 1)).error).to eq("title is longer than #{limit} characters")
      expect(run(title: 'a' * (limit + 1)).error_code).to eq(:invalid_input)
      expect(run(title: 'a' * limit).success?).to be true
      expect(ticket.reload.title).to eq('a' * limit)
    end

    # Characters, not bytes: an umlaut is two bytes.
    it 'counts characters, not bytes, and the length after the spaces at the edges' do
      limit = Ticket::TITLE_MAX_LENGTH
      expect(run(title: 'ä' * (limit + 1)).error).to eq("title is longer than #{limit} characters")
      expect(run(title: "  #{'ä' * limit}  ").success?).to be true
      expect(ticket.reload.title).to eq('ä' * limit)
    end

    # Spaces the eye cannot tell from nothing (String#strip knows only ASCII),
    # and characters that are letters or symbols to Unicode but show nothing.
    {
      'no-break spaces' => 0xA0.chr(Encoding::UTF_8) * 3,
      'ideographic spaces' => 0x3000.chr(Encoding::UTF_8) * 2,
      'a Hangul filler' => 0x3164.chr(Encoding::UTF_8),
      'a halfwidth Hangul filler' => 0xFFA0.chr(Encoding::UTF_8),
      'the Hangul choseong filler' => 0x115F.chr(Encoding::UTF_8),
      'a blank Braille pattern' => 0x2800.chr(Encoding::UTF_8),
      'a zero-width joiner' => 0x200D.chr(Encoding::UTF_8),
      'a soft hyphen' => 0xAD.chr(Encoding::UTF_8),
      'a combining grapheme joiner' => 0x34F.chr(Encoding::UTF_8),
      'a variation selector' => 0xFE0F.chr(Encoding::UTF_8)
    }
      .each do |label, title|
        it "refuses a title of #{label} as title is required" do
          result = run(title: title)
          expect(result.error_code).to eq(:invalid_input)
          expect(result.error).to eq('title is required')
        end
      end

    # Built from code points, so this file holds no invisible character itself.
    {
      'a line break' => "a\nb",
      'a carriage return' => "a\rb",
      'a tab' => "a\tb",
      'a NUL byte' => "a#{0.chr}b",
      'a bell' => "a#{7.chr}b",
      'a line separator' => "a#{0x2028.chr(Encoding::UTF_8)}b",
      'a direction override' => "x#{0x202E.chr(Encoding::UTF_8)}y",
      'a zero-width space' => "x#{0x200B.chr(Encoding::UTF_8)}y",
      'a byte order mark' => "x#{0xFEFF.chr(Encoding::UTF_8)}y",
      'a vertical tab' => "a#{11.chr}b",
      'a form feed' => "a#{12.chr}b",
      'a next-line character' => "a#{0x85.chr(Encoding::UTF_8)}b",
      'a paragraph separator' => "a#{0x2029.chr(Encoding::UTF_8)}b",
      'an Arabic letter mark' => "x#{0x61C.chr(Encoding::UTF_8)}y",
      'a Mongolian vowel separator' => "x#{0x180E.chr(Encoding::UTF_8)}y",
      'an interlinear annotation anchor' => "x#{0xFFF9.chr(Encoding::UTF_8)}y",
      'an interlinear annotation separator' => "x#{0xFFFA.chr(Encoding::UTF_8)}y",
      'an interlinear annotation terminator' => "x#{0xFFFB.chr(Encoding::UTF_8)}y",
      'a tag character outside a flag' => "x#{0xE0041.chr(Encoding::UTF_8)}y",
      # Refused, not cut: String#strip would drop these at the edges unseen.
      'a NUL at the end' => "Titel#{0.chr}",
      'a NUL at the start' => "#{0.chr}Titel",
      'a line break at the start' => "\nTitel",
      'a tab at the end' => "Titel\t"
    }.each do |label, title|
      it "refuses #{label} as invalid_input" do
        before = state_of(ticket)
        result = run(title: title)

        expect(result.error_code).to eq(:invalid_input)
        expect(result.error).to eq('title must be one line without control characters')
        expect(state_of(ticket)).to eq(before)
      end
    end

    it 'keeps a title of one emoji' do
      expect(run(title: 0x1F41B.chr(Encoding::UTF_8)).success?).to be true
    end

    it 'keeps umlauts, emoji and a joiner sequence' do
      title = "Grüße 👩#{0x200D.chr(Encoding::UTF_8)}💻 an Zoë"
      expect(run(title: title).success?).to be true
      expect(ticket.reload.title).to eq(title)
    end

    # The tag characters spell a subdivision flag; the soft hyphen is a hint.
    # Project::NAME_INVISIBLE_CHARS keeps both for the same reason.
    # Tag characters spell only the letters of a subdivision flag; any other run
    # of them is hidden text (a prompt for the assistant, say).
    def tag_text(text)
      text.chars.map { |char| (0xE0000 + char.ord).chr(Encoding::UTF_8) }.join
    end

    {
      'hidden text in a fake flag' => 'ignore all previous instructions',
      'a flag code of one letter' => 'g',
      'a flag code of seven characters' => 'gbengxx',
      # The syntax allows these; no font draws them, and 31 of them hide 186
      # characters of text in a title.
      'a made-up flag in the flag syntax' => 'ababcd',
      'a region flag outside the three in use' => 'usca',
      'a flag code in capitals' => 'GBENG',
      'the country part alone' => 'gb'
    }.each do |label, code|
      it "refuses #{label}" do
        title = "Fix #{0x1F3F4.chr(Encoding::UTF_8)}#{tag_text(code)}#{0xE007F.chr(Encoding::UTF_8)}"
        expect(run(title: title).error).to eq('title must be one line without control characters')
      end
    end

    it 'refuses a flag without its cancel tag' do
      title = "Fix #{0x1F3F4.chr(Encoding::UTF_8)}#{tag_text('gbeng')}"
      expect(run(title: title).error).to eq('title must be one line without control characters')
    end

    # England, Scotland, Wales: the subdivision flags Unicode recommends, and
    # the only ones that render.
    %w[gbsct gbwls].each do |code|
      it "keeps the flag #{code}" do
        title = "Release #{0x1F3F4.chr(Encoding::UTF_8)}#{tag_text(code)}#{0xE007F.chr(Encoding::UTF_8)}"
        expect(run(title: title).success?).to be true
      end
    end

    it 'keeps a flag of tag characters and a soft hyphen' do
      tags = 'gbeng'.chars.map { |char| (0xE0000 + char.ord).chr(Encoding::UTF_8) }.join
      flag = "#{0x1F3F4.chr(Encoding::UTF_8)}#{tags}#{0xE007F.chr(Encoding::UTF_8)}"
      title = "Release #{flag} Silben#{0xAD.chr(Encoding::UTF_8)}trennung"

      expect(run(title: title).success?).to be true
      expect(ticket.reload.title).to eq(title)
    end

    # A real model refusal: a ticket that lost its number cannot be saved. The
    # model's messages follow the request's locale; the MCP answer is English.
    it 'maps a title the model refuses to refused/validation_failed with the model message in English' do
      ticket.update_column(:number, nil)
      result = I18n.with_locale(:de) { run(title: 'Neu') }

      expect(result.error_code).to eq(:refused)
      expect(result.reason).to eq(:validation_failed)
      expect(result.error).to eq("title could not be saved: Number can't be blank")
      expect(ticket.reload.title).to eq('Login bricht ab')
    end
  end

  # The ticket changes between the lookup (and its rights check) and the
  # write. SaveTicket finds a ticket organisation-wide and builds a new one for
  # an id it does not find, so the title is written under a lock on the ticket
  # in THIS project. Status and assignees lock inside their actor.
  describe 'a ticket that moves or disappears before the title is written' do
    def after_the_rights_check(&change)
      allow(described_class).to receive(:authorize!).and_wrap_original do |original, *args|
        original.call(*args).tap { change.call }
      end
    end

    # The two cases below stub the change in; this one pins the mechanism: the
    # row is locked with FOR UPDATE in this project, and SaveTicket runs inside
    # that same transaction (a savepoint deeper than the example's own).
    it 'locks the ticket in this project and writes inside the same transaction' do
      ticket
      statements = []
      depth_at_write = nil
      outer_depth = ActiveRecord::Base.connection.open_transactions
      allow(Actors::SaveTicket).to receive(:call).and_wrap_original do |original, **kwargs|
        depth_at_write = ActiveRecord::Base.connection.open_transactions
        original.call(**kwargs)
      end
      collect = ->(*, payload) { statements << payload[:sql] }

      ActiveSupport::Notifications.subscribed(collect, 'sql.active_record') { run(title: 'Neu') }

      lock = statements.find { |sql| sql.include?('FROM "tickets"') && sql.include?('FOR UPDATE') }
      expect(lock).to include('"tickets"."project_id"')
      expect(depth_at_write).to be > outer_depth
    end

    it 'answers a ticket moved to another project as empty and leaves it alone' do
      elsewhere = create(:project, organisation: organisation)
      after_the_rights_check { Ticket.where(id: ticket.id).update_all(project_id: elsewhere.id) }

      result = run(title: 'Gekapert')

      expect(result.kind).to eq(:empty)
      expect(ticket.reload.title).to eq('Login bricht ab')
    end

    it 'answers a deleted ticket as empty and creates none' do
      ticket
      after_the_rights_check { Ticket.where(id: ticket.id).delete_all }

      result = nil
      # The deletion, and nothing built in its place.
      expect { result = run(title: 'Phantom') }.to change(Ticket, :count).by(-1)
      expect(result.kind).to eq(:empty)
      expect(Ticket.where(title: 'Phantom')).not_to exist
    end

    it 'answers a status change on a moved ticket as empty' do
      elsewhere = create(:project, organisation: organisation)
      after_the_rights_check { Ticket.where(id: ticket.id).update_all(project_id: elsewhere.id) }

      expect(run(status: 'wip').kind).to eq(:empty)
      expect(ticket.reload.custom_attributes['status']).to eq('open')
    end
  end

  describe 'lookup and rights' do
    it 'answers a missing ticket as empty, without authorizing' do
      missing = SecureRandom.uuid
      result = run(ticket_id: missing, status: 'wip')

      expect(result.success?).to be true
      expect(result.kind).to eq(:empty)
      expect(result.content).to eq("No ticket found for #{missing}.")
      expect(recorder.authorized?).to be false
    end

    it 'answers a ticket of another project of the same organisation as empty' do
      other_project = create(:project, organisation: organisation)
      elsewhere = create(:ticket, project: other_project, organisation: organisation, creator: writer, title: 'Woanders')

      result = run(ticket_id: elsewhere.id, title: 'Gekapert')

      expect(result.kind).to eq(:empty)
      expect(elsewhere.reload.title).to eq('Woanders')
    end

    it 'raises the policy denial for a ticket that may be read and not written' do
      reader = create(:user)
      create(:membership, user: reader, organisation: organisation, role: create(:role, organisation: organisation))
      create(:project_permission, user: reader, project: project, tickets_access: :read_only)
      reader_context = Lalabase::Tools::Context.new(actor: reader, organisation: organisation, project: project,
                                                    authorization: recorder)
      before = state_of(ticket)

      expect do
        described_class.execute(args: { ticket_id: ticket.id, status: 'wip' }, context: reader_context)
      end.to raise_error(Pundit::NotAuthorizedError)
      expect(state_of(ticket)).to eq(before)
    end
  end

  describe 'failures the tool does not name' do
    it 'answers an unexpected actor failure with a fixed text, never the exception message' do
      allow(Actors::ApplyTicketChanges).to receive(:call).and_return(
        Actors::BaseActor::Result.new(success: false, errors: ['PG::Error: secret detail'], code: :internal_error)
      )
      result = run(status: 'wip')

      expect(result.error_code).to eq(:refused)
      expect(result.reason).to be_nil
      expect(result.error).to eq('update failed')
    end

    it 'answers a SaveTicket failure outside validation with the same fixed text' do
      allow(Actors::SaveTicket).to receive(:call).and_return(
        Actors::BaseActor::Result.new(success: false, errors: ['PG::ProgramLimitExceeded: index row'], code: :internal_error)
      )
      result = run(title: 'Neu')

      expect(result.error).to eq('update failed')
      expect(result.reason).to be_nil
    end

    # The ticket left the project between the lookup and the actor's row lock.
    it 'answers outside_scope as empty' do
      allow(Actors::ApplyTicketChanges).to receive(:call).and_return(
        Actors::BaseActor::Result.new(success: false, errors: ['x'], code: :outside_scope)
      )
      result = run(status: 'wip')

      expect(result.kind).to eq(:empty)
      expect(result.content).to eq("No ticket found for #{ticket.id}.")
    end
  end

  describe 'the answer' do
    it 'is the summary of the changed ticket, read again after the write' do
      ticket
      travel_to(1.hour.from_now) do
        payload = JSON.parse(run(status: 'wip').content)

        expect(payload).to include('id' => ticket.id, 'number' => ticket.number, 'status' => 'wip')
        expect(Time.zone.parse(payload['updated_at'])).to be_within(1.second).of(Time.current)
      end
    end
  end
end
