# frozen_string_literal: true

require 'rails_helper'

# What: POST /api/v1/tickets/:id/changes changes one thing on a ticket, by the rule
#       the MCP tool update_ticket changes it by (Tickets::Change, cli_rest_plan
#       D3): the title, the status, or the assignees added and removed against
#       the current list.
# Type: request spec.
# Why:  PATCH /tickets/:id REPLACES the assignee list and knows no title, so the
#       terminal client gets its own endpoint. Pinned here: a person removed who
#       was not named, a person who may not be assigned passed over silently, a
#       status outside the project's catalogue written or another JSONB key
#       touched, a ticket that moved or was deleted changed or built anew, an
#       unreadable ticket telling itself apart from a missing one, a read-only
#       ticket or token writing, a replay writing twice, an exception text
#       reaching the client.
RSpec.describe 'API V1 ticket changes', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, language_preference: 'en') }
  let(:colleague) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let(:project) { with_statuses(ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }) }
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: 'Login bricht ab',
                      custom_attributes: { 'status' => statuses.first, 'priority' => 'high' })
    end
  end
  let(:statuses) { in_org { TicketAttributeDefinition.ordered_value_keys_for(project, 'status') } }
  let(:pat) { build_pat(user) }

  before do
    Prosopite.pause do
      in_org do
        create(:membership, user: user, organisation: organisation, role: role, active: true)
        create(:membership, user: colleague, organisation: organisation, role: role, active: true)
        create(:project_permission, user: user, project: project, tickets_access: :read_write)
        create(:project_permission, user: colleague, project: project, tickets_access: :read_write)
      end
      ticket
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def in_org(&) = ActsAsTenant.with_tenant(organisation, &)

  # The status field the board uses: a single select named "status".
  def with_statuses(target, values = %w[open wip])
    ActsAsTenant.with_tenant(target.organisation) do
      create(:ticket_attribute_definition,
             project: target, name: 'status', field_type: 'select', position: 1,
             labels: { 'de' => 'Status', 'en' => 'Status' },
             options: { 'allowed_values' => values.map { |value| { 'value' => value, 'labels' => { 'de' => "Label #{value}" } } } })
    end
    target
  end

  def build_pat(owner, read_only: false, project_scopes: {})
    build(:personal_access_token, user: owner, organisations: [organisation], read_only: read_only,
                                  project_scopes: project_scopes).tap do |token|
      token.token_hash = nil
      token.token_prefix = nil
      token.generate_token!
    end
  end

  def headers(token: pat, key: nil, json: true)
    { 'Authorization' => "Bearer #{token.token}" }.tap do |h|
      h['Idempotency-Key'] = key if key
      h['Content-Type'] = 'application/json' if json
    end
  end

  # JSON, for values a form cannot carry (numbers, null, lists).
  def send_change(fields, ticket_id: ticket.id, token: pat, key: nil)
    post "/api/v1/tickets/#{ticket_id}/changes", params: { change: fields }.to_json, headers: headers(token: token, key: key)
  end

  def change_raw(body, ticket_id: ticket.id)
    post "/api/v1/tickets/#{ticket_id}/changes", params: body, headers: headers
  end

  def change_form(params, ticket_id: ticket.id)
    post "/api/v1/tickets/#{ticket_id}/changes", params: params, headers: headers(json: false)
  end

  # Multipart, where a text part may name a charset of its own (Rack tags the
  # string with it); JSON and forms always arrive as UTF-8.
  def change_multipart(name, type, bytes)
    boundary = 'r3b-boundary'
    raw = "--#{boundary}\r\nContent-Disposition: form-data; name=\"change[#{name}]\"\r\nContent-Type: #{type}\r\n\r\n".b
    raw << bytes.b << "\r\n--#{boundary}--\r\n".b
    post "/api/v1/tickets/#{ticket.id}/changes", params: raw,
                                                 headers: headers(json: false).merge('Content-Type' => "multipart/form-data; boundary=#{boundary}")
  end

  def body = response.parsed_body

  def reloaded = ActsAsTenant.without_tenant { Ticket.find(ticket.id) }

  def assignee_ids
    ActsAsTenant.without_tenant { TicketAssignment.where(ticket_id: ticket.id).pluck(:user_id) }
  end

  # Everything a write could leave behind, organisation-wide.
  def written
    Prosopite.pause do
      ActsAsTenant.without_tenant do
        [TicketBulkRun.count, Activity.count, TicketAssignment.count, Ticket.order(:id).pluck(:title, :custom_attributes)]
      end
    end
  end

  def assign(*people)
    Prosopite.pause { in_org { people.each { |person| ticket.ticket_assignments.create!(user: person) } } }
  end

  # Written out, not read through I18n.t as the controller reads them: a missing
  # or misspelt key would be compared with itself, and an English key that is
  # missing falls back to the German text on both sides.
  def invalid_input(text)
    { 'error' => 'validation_failed', 'code' => 'invalid_input', 'errors' => [text] }
  end

  def refused(reason, *texts)
    { 'error' => reason, 'code' => 'refused', 'reason' => reason, 'errors' => texts }
  end

  def expect_invalid_input(text)
    expect(response).to have_http_status(:unprocessable_content)
    expect(body).to eq(invalid_input(text))
  end

  def expect_refused(reason, *texts)
    expect(response).to have_http_status(:unprocessable_content)
    expect(body).to eq(refused(reason, *texts))
  end

  def one_kind = 'Give exactly one change: title, status, or add_assignee_ids and remove_assignee_ids.'

  def unknown_keys = 'A change takes only title, status, add_assignee_ids and remove_assignee_ids.'

  describe 'a status' do
    it 'sets a key from the project catalogue and answers the summary, as PATCH does' do
      expect { send_change({ status: statuses.last }) }.to change { TicketBulkRun.unscoped.count }.by(1)

      expect(response).to have_http_status(:ok)
      fresh = reloaded
      summary = Prosopite.pause { in_org { Tickets::Serializer.new(current_user: user).summary(fresh) } }
      expect(response.body).to eq({ data: summary }.to_json)
      expect(body.dig('data', 'status')).to eq(statuses.last)
    end

    it 'leaves every other key of the JSONB as it was' do
      send_change({ status: statuses.last })
      expect(reloaded.custom_attributes).to eq('status' => statuses.last, 'priority' => 'high')
    end

    it 'takes a key with spaces around it' do
      send_change({ status: " #{statuses.last} " })
      expect(response).to have_http_status(:ok)
      expect(reloaded.custom_attributes['status']).to eq(statuses.last)
    end

    # Display labels, other spellings, the keys of other projects: only the keys.
    ['Label wip', 'WIP', 'erledigt'].each do |value|
      it "refuses #{value.inspect} as no status of this project, writing nothing" do
        before = written
        send_change({ status: value })

        expect_refused('value_not_allowed', 'This is no status of this project; use a key from meta.available_statuses.')
        expect(written).to eq(before)
      end
    end

    it 'never repeats the value it refused' do
      value = "x#{27.chr}[31mROT\nzwei"
      send_change({ status: value })
      expect(response.body).not_to include('ROT')
    end

    it 'answers in the language of the token owner' do
      Prosopite.pause { user.update!(language_preference: 'de') }
      send_change({ status: 'erledigt' })

      expect_refused('value_not_allowed',
                     'Das ist kein Status dieses Projekts; bitte einen Schlüssel aus meta.available_statuses verwenden.')
    end

    context 'in a project without a status field' do
      let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
      let(:statuses) { ['frei'] }

      it 'refuses, writing nothing' do
        before = written
        send_change({ status: 'wip' })

        expect_refused('no_status_field', 'This project has no status field.')
        expect(written).to eq(before)
      end

      # The board writes any active field of that name.
      it 'refuses when "status" is a checkbox' do
        Prosopite.pause do
          in_org do
            create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'checkbox', position: 1,
                                                 labels: { 'de' => 'Status', 'en' => 'Status' }, options: {})
          end
        end
        before = written
        send_change({ status: 'true' })

        expect_refused('no_status_field', 'This project has no status field.')
        expect(written).to eq(before)
      end
    end
  end

  describe 'assignees' do
    it 'adds a person and keeps who is on the ticket' do
      assign(colleague)
      send_change({ add_assignee_ids: [user.id] })

      expect(response).to have_http_status(:ok)
      expect(assignee_ids).to contain_exactly(user.id, colleague.id)
      expect(body.dig('data', 'assignees').pluck('id')).to contain_exactly(user.id, colleague.id)
    end

    it 'removes only the person it names' do
      assign(colleague, user)
      send_change({ remove_assignee_ids: [colleague.id] })

      expect(response).to have_http_status(:ok)
      expect(assignee_ids).to eq([user.id])
    end

    it 'reads "me" as the token owner' do
      assign(colleague)
      send_change({ add_assignee_ids: ['me'] })

      expect(response).to have_http_status(:ok)
      expect(assignee_ids).to contain_exactly(user.id, colleague.id)
    end

    it 'removes the token owner with "me"' do
      assign(colleague, user)
      send_change({ remove_assignee_ids: ['me'] })

      expect(assignee_ids).to eq([colleague.id])
    end

    it 'adds and removes in one change' do
      assign(colleague)
      send_change({ add_assignee_ids: ['me'], remove_assignee_ids: [colleague.id] })

      expect(response).to have_http_status(:ok)
      expect(assignee_ids).to eq([user.id])
    end

    it 'takes the lists from a form too' do
      assign(colleague)
      change_form({ change: { add_assignee_ids: ['me'] } })

      expect(response).to have_http_status(:ok)
      expect(assignee_ids).to contain_exactly(user.id, colleague.id)
    end

    it 'refuses the same person in both lists, also as "me"' do
      before = written
      send_change({ add_assignee_ids: ['me'], remove_assignee_ids: [user.id] })

      expect_invalid_input('add_assignee_ids and remove_assignee_ids name the same user.')
      expect(written).to eq(before)
    end

    it 'takes 50 ids in a list and refuses 51' do
      at_limit = Array.new(Tickets::Change::MAX_ASSIGNEE_IDS) { SecureRandom.uuid }

      send_change({ add_assignee_ids: at_limit + [SecureRandom.uuid] })
      expect_invalid_input('Name at most 50 users per list.')

      # At the limit the shape passes; these random people are then refused by the project.
      send_change({ add_assignee_ids: at_limit })
      expect(body['reason']).to eq('value_not_allowed')
    end

    {
      'a list that is no list' => [{ add_assignee_ids: 'me' }, 'Give add_assignee_ids as a list of user ids or "me".'],
      'a number in the list' => [{ remove_assignee_ids: [5] }, 'Give remove_assignee_ids as a list of user ids or "me".'],
      'null as the list' => [{ add_assignee_ids: nil }, 'Give add_assignee_ids as a list of user ids or "me".'],
      'an entry that is no id' => [{ add_assignee_ids: ['oops'] }, 'add_assignee_ids holds a value that is no user id and not "me".'],
      'empty lists' => [{ add_assignee_ids: [], remove_assignee_ids: [] }, 'Name at least one user in add_assignee_ids or remove_assignee_ids.']
    }.each do |label, (fields, text)|
      it "refuses #{label}, writing nothing" do
        assign(colleague)
        before = written
        send_change(fields)

        expect_invalid_input(text)
        expect(written).to eq(before)
      end
    end

    # Rails drops a JSON null from a list before the rule sees it: it names nobody.
    it 'reads a list of nulls as naming nobody' do
      send_change({ add_assignee_ids: [nil] })
      expect_invalid_input('Name at least one user in add_assignee_ids or remove_assignee_ids.')
    end

    it 'refuses a person the project does not offer loudly, and takes nobody off' do
      assign(colleague)
      before = written
      send_change({ add_assignee_ids: [SecureRandom.uuid], remove_assignee_ids: [colleague.id] })

      expect_refused('value_not_allowed', 'A user in this change cannot be assigned in this project.')
      expect(written).to eq(before)
    end

    it 'refuses a member without access to the project, in the same words' do
      outsider = Prosopite.pause do
        create(:user).tap { |person| in_org { create(:membership, user: person, organisation: organisation, role: role, active: true) } }
      end
      before = written
      send_change({ add_assignee_ids: [outsider.id] })

      expect_refused('value_not_allowed', 'A user in this change cannot be assigned in this project.')
      expect(written).to eq(before)
    end

    it 'refuses a person who lost access meanwhile, and takes nobody off' do
      assign(colleague)
      allow_any_instance_of(Ticket).to receive(:assignable_user_ids).and_return([])
      before = written
      send_change({ add_assignee_ids: ['me'], remove_assignee_ids: [colleague.id] })

      expect_refused('user_not_assignable', 'Nothing was changed: a person in this change no longer has access to this project.')
      expect(written).to eq(before)
    end

    context 'with a stale assignee, who lost access since' do
      let(:stale) do
        Prosopite.pause do
          create(:user).tap { |person| in_org { create(:membership, user: person, organisation: organisation, role: role, active: false) } }
        end
      end

      it 'keeps them when they are not named' do
        assign(stale)
        send_change({ add_assignee_ids: ['me'] })

        expect(response).to have_http_status(:ok)
        expect(assignee_ids).to contain_exactly(stale.id, user.id)
      end

      it 'takes them off when they are named' do
        assign(stale)
        send_change({ add_assignee_ids: ['me'], remove_assignee_ids: [stale.id] })

        expect(response).to have_http_status(:ok)
        expect(assignee_ids).to eq([user.id])
      end
    end
  end

  describe 'a title' do
    it 'renames the ticket and leaves everyone on it' do
      assign(colleague)
      send_change({ title: '  Login bricht in Safari ab  ' })

      expect(response).to have_http_status(:ok)
      expect(body.dig('data', 'title')).to eq('Login bricht in Safari ab')
      expect(reloaded.title).to eq('Login bricht in Safari ab')
      expect(reloaded.custom_attributes).to eq('status' => statuses.first, 'priority' => 'high')
      expect(assignee_ids).to eq([colleague.id])
    end

    it 'runs no bulk run' do
      expect { send_change({ title: 'Neu' }) }.not_to(change { TicketBulkRun.unscoped.count })
    end

    it 'takes 255 characters' do
      send_change({ title: 'ä' * Ticket::TITLE_MAX_LENGTH })

      expect(response).to have_http_status(:ok)
      expect(reloaded.title).to eq('ä' * Ticket::TITLE_MAX_LENGTH)
    end

    {
      'nothing' => ['', 'The title (change[title]) has no visible text.'],
      'spaces alone' => ['   ', 'The title (change[title]) has no visible text.'],
      '256 characters' => ['a' * 256, 'The title (change[title]) is longer than 255 characters.'],
      'a line break' => ["a\nb", 'The title (change[title]) must be one line without control characters.'],
      'a control character' => ["a#{7.chr}b", 'The title (change[title]) must be one line without control characters.'],
      'a NUL byte' => ["a#{0.chr}b", 'The title (change[title]) must be one line without control characters.'],
      'a zero-width space' => ["x#{0x200B.chr(Encoding::UTF_8)}y", 'The title (change[title]) must be one line without control characters.'],
      'a number' => [5, 'Give the title (change[title]) as text.'],
      'null' => [nil, 'Give the title (change[title]) as text.'],
      'a list' => [['Neu'], 'Give the title (change[title]) as text.']
    }.each do |label, (value, text)|
      it "refuses #{label}, writing nothing" do
        before = written
        send_change({ title: value })

        expect_invalid_input(text)
        expect(written).to eq(before)
      end
    end

    # A real model refusal: a ticket that lost its number cannot be saved.
    it 'answers a title the model refuses with the messages of the model' do
      Prosopite.pause { in_org { ticket.update_column(:number, nil) } }
      send_change({ title: 'Neu' })

      expect_refused('validation_failed', 'The title could not be saved.', "Number can't be blank")
      expect(reloaded.title).to eq('Login bricht ab')
    end
  end

  describe 'what a change is' do
    {
      'title and status' => { title: 'x', status: 'wip' },
      'status and a list' => { status: 'wip', add_assignee_ids: ['me'] },
      'an empty title next to a status' => { title: '', status: 'wip' },
      'a null title next to a status' => { title: nil, status: 'wip' },
      'an empty list next to a title' => { title: 'x', remove_assignee_ids: [] },
      'an empty object' => {}
    }.each do |label, fields|
      it "refuses #{label}, by the keys present, writing nothing" do
        before = written
        send_change(fields)

        expect_invalid_input(one_kind)
        expect(written).to eq(before)
      end
    end

    { 'no body' => '{}', 'a string' => '{"change":"status"}', 'a number' => '{"change":5}', 'null' => '{"change":null}',
      'a list' => '{"change":[{"status":"open"}]}', 'the change on top' => '{"status":"open"}' }.each do |label, raw|
      it "refuses #{label} in place of a change" do
        before = written
        change_raw(raw)

        expect_invalid_input(one_kind)
        expect(written).to eq(before)
      end
    end

    it 'refuses a key it does not know instead of ignoring it, and repeats nothing of it' do
      before = written
      send_change({ status: 'wip', priority: 'low', "x#{27.chr}[2J" => 1 })

      expect_invalid_input(unknown_keys)
      expect(response.body).not_to include('priority')
      expect(written).to eq(before)
    end

    # The list PATCH takes REPLACES; a guess at it must not read as done.
    it 'refuses assignee_ids' do
      before = written
      send_change({ assignee_ids: [user.id] })

      expect_invalid_input(unknown_keys)
      expect(written).to eq(before)
    end

    # Never reaches the rule: Rails refuses raw bytes in a form as a 400.
    it 'writes nothing for a key of raw bytes in a form' do
      before = written
      post "/api/v1/tickets/#{ticket.id}/changes", params: 'change[x%FF]=1&change[status]=wip',
                                                   headers: headers(json: false).merge('Content-Type' => 'application/x-www-form-urlencoded')

      expect(response).to have_http_status(:bad_request)
      expect(written).to eq(before)
    end

    # The patterns of the title rule raise on these; a part named UTF-16 never
    # gets here, Rack's own parser raises on it.
    { 'Latin-1' => ['text/plain; charset=iso-8859-1', "M\xFCller"], 'binary' => ['text/plain; charset=binary', "M\xC3\xBCller"] }.each do |label, (type, bytes)|
      it "refuses a #{label} part instead of crashing on it" do
        before = written
        change_multipart('title', type, bytes)

        expect_invalid_input('The change cannot be read as UTF-8.')
        expect(written).to eq(before)
      end
    end

    it 'refuses a file in place of a title' do
      upload = Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/test_file.txt'), 'text/plain')
      before = written
      post "/api/v1/tickets/#{ticket.id}/changes", params: { change: { title: upload } }, headers: headers(json: false)

      expect_invalid_input('Give the title (change[title]) as text.')
      expect(written).to eq(before)
    end

    # The body is read before any lookup, so it cannot tell a ticket from no ticket.
    it 'answers a body that is no JSON with a 400, the same for a missing ticket' do
      change_raw('{"change":')
      first = [response.status, response.body]
      change_raw('{"change":', ticket_id: SecureRandom.uuid)

      expect(response).to have_http_status(:bad_request)
      expect(body).to include('error' => 'bad_request', 'code' => 'invalid_input')
      expect([response.status, response.body]).to eq(first)
    end

    it 'takes a multipart part in UTF-8' do
      change_multipart('title', 'text/plain; charset=utf-8', 'Müller')

      expect(response).to have_http_status(:ok)
      expect(reloaded.title).to eq('Müller')
    end
  end

  describe 'rights and existence' do
    let(:not_found_body) { '{"error":"not_found","code":"not_found"}' }

    # Input of every class: fine, unusable, unknown, none.
    inputs = {
      'a usable change' => '{"change":{"title":"Gekapert"}}',
      'a mixed change' => '{"change":{"title":"x","status":"y"}}',
      'an unknown key' => '{"change":{"priority":"low"}}',
      'a title it refuses' => '{"change":{"title":""}}',
      'no change' => '{}'
    }

    inputs.each do |label, raw|
      describe "with #{label}" do
        it 'answers a missing ticket 404' do
          before = written
          change_raw(raw, ticket_id: SecureRandom.uuid)

          expect(response).to have_http_status(:not_found)
          expect(response.body).to eq(not_found_body)
          expect(written).to eq(before)
        end

        it 'answers a ticket the owner may not read with the same 404' do
          hidden = Prosopite.pause do
            in_org do
              notes_only = create(:project, organisation: organisation)
              create(:project_permission, user: user, project: notes_only, notes_access: :read_only)
              create(:ticket, project: notes_only, organisation: organisation, creator: colleague, title: 'Vertraulich')
            end
          end
          before = written
          change_raw(raw, ticket_id: hidden.id)

          expect(response).to have_http_status(:not_found)
          expect(response.body).to eq(not_found_body)
          expect(written).to eq(before)
        end

        it 'answers a ticket of a foreign organisation with the same 404' do
          foreign = Prosopite.pause do
            other = create(:organisation)
            ActsAsTenant.with_tenant(other) do
              create(:ticket, organisation: other, project: create(:project, organisation: other), creator: create(:user), title: 'Fremd')
            end
          end
          before = written
          change_raw(raw, ticket_id: foreign.id)

          expect(response).to have_http_status(:not_found)
          expect(response.body).to eq(not_found_body)
          expect(written).to eq(before)
        end

        it 'answers a ticket that may be read and not written 403, before the input' do
          Prosopite.pause { in_org { ProjectPermission.find_by!(user: user, project: project).update!(tickets_access: :read_only) } }
          before = written
          change_raw(raw)

          expect(response).to have_http_status(:forbidden)
          expect(response.body).to eq('{"error":"forbidden","code":"forbidden"}')
          expect(written).to eq(before)
        end

        it 'answers a read-only token 403 read_only, before anything' do
          read_only = Prosopite.pause { build_pat(user, read_only: true) }
          before = written
          expect(Ticket).not_to receive(:where)
          post "/api/v1/tickets/#{ticket.id}/changes", params: raw, headers: headers(token: read_only)

          expect(response).to have_http_status(:forbidden)
          expect(response.body).to eq('{"error":"forbidden","code":"read_only"}')
          expect(written).to eq(before)
        end
      end
    end

    it 'answers a malformed id with the same 404' do
      change_raw('{"change":{"title":"x"}}', ticket_id: 'oops')

      expect(response).to have_http_status(:not_found)
      expect(response.body).to eq(not_found_body)
    end

    it 'answers a ticket outside the token with the same 404' do
      elsewhere = Prosopite.pause { in_org { create(:project, organisation: organisation) } }
      narrow = Prosopite.pause { build_pat(user, project_scopes: { organisation => [elsewhere] }) }
      before = written
      send_change({ title: 'Gekapert' }, token: narrow)

      expect(response).to have_http_status(:not_found)
      expect(response.body).to eq(not_found_body)
      expect(written).to eq(before)
    end

    it 'answers a token of a deactivated member with the same 404' do
      Prosopite.pause { in_org { Membership.find_by!(user: user, organisation: organisation).update!(active: false) } }
      before = written
      send_change({ title: 'Gekapert' })

      expect(response).to have_http_status(:not_found)
      expect(response.body).to eq(not_found_body)
      expect(written).to eq(before)
    end

    it 'lets an account admin without a project permission change the ticket' do
      admin = Prosopite.pause do
        create(:user).tap do |person|
          in_org { create(:membership, user: person, organisation: organisation, role: create(:admin_role, organisation: organisation)) }
        end
      end
      send_change({ status: statuses.last }, token: Prosopite.pause { build_pat(admin) })

      expect(response).to have_http_status(:ok)
      expect(reloaded.custom_attributes['status']).to eq(statuses.last)
    end

    it 'asks the write right of the ticket itself' do
      expect_any_instance_of(TicketPolicy).to receive(:update?).and_call_original
      send_change({ title: 'Neu' })
      expect(response).to have_http_status(:ok)
    end
  end

  # The ticket changes after the rights check. SaveTicket finds a ticket
  # organisation-wide and builds a new one for an id it does not find.
  describe 'a ticket that leaves after the rights check' do
    def after_the_rights_check(&block)
      allow_any_instance_of(Tickets::Change).to receive(:write).and_wrap_original do |original, **kwargs|
        block.call
        original.call(**kwargs)
      end
    end

    { 'title' => { title: 'Gekapert' }, 'status' => { status: 'wip' }, 'assignees' => { add_assignee_ids: ['me'] } }.each do |kind, fields|
      it "answers a #{kind} change on a moved ticket like a missing one and leaves it alone" do
        elsewhere = Prosopite.pause { in_org { create(:project, organisation: organisation) } }
        after_the_rights_check { ActsAsTenant.without_tenant { Ticket.where(id: ticket.id).update_all(project_id: elsewhere.id) } }
        send_change(fields)

        expect(response).to have_http_status(:not_found)
        expect(response.body).to eq('{"error":"not_found","code":"not_found"}')
        expect(reloaded).to have_attributes(title: 'Login bricht ab', custom_attributes: { 'status' => statuses.first, 'priority' => 'high' })
        expect(assignee_ids).to be_empty
      end
    end

    it 'builds no ticket for a deleted one' do
      after_the_rights_check { ActsAsTenant.without_tenant { Ticket.where(id: ticket.id).delete_all } }
      send_change({ title: 'Phantom' })

      expect(response).to have_http_status(:not_found)
      expect(response.body).to eq('{"error":"not_found","code":"not_found"}')
      expect(ActsAsTenant.without_tenant { Ticket.where(title: 'Phantom') }).not_to exist
    end
  end

  describe 'a failure the rule does not name' do
    let(:secret) { 'PG::Error: secret detail' }

    def failing(code)
      Actors::BaseActor::Result.new(success: false, errors: [secret], code: code)
    end

    it 'answers an unexpected actor failure 500, without its message' do
      allow(Actors::ApplyTicketChanges).to receive(:call).and_return(failing(:internal_error))
      send_change({ status: statuses.last })

      expect(response).to have_http_status(:internal_server_error)
      expect(body).to eq('error' => 'internal_error', 'code' => 'refused', 'reason' => 'internal_error')
      expect(response.body).not_to include(secret)
    end

    it 'does the same for a title' do
      allow(Actors::SaveTicket).to receive(:call).and_return(failing(:internal_error))
      send_change({ title: 'Neu' })

      expect(response).to have_http_status(:internal_server_error)
      expect(response.body).not_to include(secret)
    end

    it 'never repeats the text of any other code' do
      allow(Actors::ApplyTicketChanges).to receive(:call).and_return(failing(:stale_object))
      send_change({ status: statuses.last })

      expect(response).to have_http_status(:internal_server_error)
      expect(response.body).not_to include(secret)
    end
  end

  describe 'idempotency' do
    let(:key) { 'r3b-term-1' }

    it 'answers a repeated key with the first answer and writes once' do
      send_change({ status: statuses.last }, key: key)
      first = [response.status, response.body]
      before = written

      send_change({ status: statuses.last }, key: key)

      expect([response.status, response.body]).to eq(first)
      expect(written).to eq(before)
    end

    it 'keeps one run and one activity across the replay' do
      expect do
        send_change({ add_assignee_ids: ['me'] }, key: key)
        send_change({ add_assignee_ids: ['me'] }, key: key)
      end.to change { ActsAsTenant.without_tenant { [TicketBulkRun.count, Activity.where(trackable_id: ticket.id).count] } }.by([1, 1])
    end

    it 'refuses the key with another body' do
      send_change({ status: statuses.last }, key: key)
      before = written

      send_change({ status: statuses.first }, key: key)

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['error']).to eq('idempotency_key_reused')
      expect(body['code']).to eq('invalid_input')
      expect(written).to eq(before)
    end

    # A refused write is not pinned to its key: once the project offers the
    # status, the same request with the same key writes.
    it 'does not store a refused change' do
      send_change({ status: 'review' }, key: key)
      expect(body['reason']).to eq('value_not_allowed')

      Prosopite.pause do
        in_org do
          definition = project.ticket_attribute_definitions.find_by!(name: 'status')
          definition.update!(options: { 'allowed_values' => definition.options['allowed_values'] +
                                                              [{ 'value' => 'review', 'labels' => { 'de' => 'review' } }] })
        end
      end
      send_change({ status: 'review' }, key: key)

      expect(response).to have_http_status(:ok)
      expect(reloaded.custom_attributes['status']).to eq('review')
    end
  end

  describe 'PATCH beside it' do
    it 'still replaces the list, and takes no title' do
      assign(colleague)
      patch "/api/v1/tickets/#{ticket.id}", params: { ticket: { assignee_ids: [user.id], title: 'Neu' } }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      expect(assignee_ids).to eq([user.id])
      expect(reloaded.title).to eq('Login bricht ab')
    end
  end
end
