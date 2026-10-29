# frozen_string_literal: true

require 'rails_helper'

# Missing and unreadable UUIDs have the same HTTP contract on all seven ticket
# member routes. Query counts deliberately differ: tenant discovery reads only
# the two routing IDs before the scoped lookup. Each example sends one request.
RSpec.describe 'REST ticket existence', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:admin) { false }
  let(:ticket_access) { :no_access }
  let(:project_access) { true }
  let(:read_only) { false }
  let(:all_organisations) { false }
  let(:token_organisations) { [organisation] }
  let(:project_scopes) { {} }
  let(:can_create_time) { true }
  let(:role) { create(:role, organisation: organisation, title: admin ? 'account_admin' : 'Reader') }
  let(:membership) { create(:membership, user: user, organisation: organisation, role: role, active: true) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: user) }
  let(:pat) do
    create(:personal_access_token, user: user, organisations: token_organisations,
                                   project_scopes: project_scopes, read_only: read_only,
                                   all_organisations: all_organisations, last_used_at: Time.current)
  end

  before do
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        membership
        project
        create(:project_permission, user: user, project: project, notes_access: :read_only, tickets_access: ticket_access) if project_access
        TimeSessionPermission.create!(user: user, project: project, can_create_own: can_create_time, can_view_own: true)
        ticket
        pat
      end
    end
    ActsAsTenant.current_tenant = nil
  end

  def request_ticket(verb, suffix, payload, id: ticket.id)
    public_send(verb, "/api/v1/tickets/#{id}#{suffix}", params: payload,
                                                        headers: { 'Authorization' => "Bearer #{pat.token}" }, as: :json)
  end

  # Assertion reads are outside Prosopite's request scan, just like fixture setup.
  def domain_state
    Prosopite.pause do
      ActsAsTenant.without_tenant { [Ticket.find(ticket.id).attributes, Post.count, TimeSession.count] }
    end
  end

  def expect_refusal(verb, suffix, payload, id:, status: :not_found, error: 'not_found', code: 'not_found')
    before = domain_state
    request_ticket(verb, suffix, payload, id: id)
    expect(domain_state).to eq(before)
    expect(response).to have_http_status(status)
    expect(response.body).to eq({ error: error, code: code }.to_json)
  end

  def member_of(org, admin: false)
    ActsAsTenant.with_tenant(org) do
      other_role = create(:role, organisation: org, title: admin ? 'account_admin' : 'Reader')
      create(:membership, user: user, organisation: org, role: other_role, active: true)
    end
  end

  routes = [
    [:get, '', {}],
    [:patch, '', { ticket: { status: 'closed' } }],
    [:get, '/activities', {}],
    [:get, '/attachments', {}],
    [:get, '/time_sessions', {}],
    [:post, '/time_sessions', { time_session: { duration_minutes: 30 } }],
    [:post, '/posts', { post: { body: 'A public comment' } }]
  ]

  routes.each do |verb, suffix, payload|
    describe "#{verb.upcase} /tickets/:id#{suffix}" do
      it 'conceals an unreadable ticket even when the project is reachable through notes' do
        expect_refusal(verb, suffix, payload, id: ticket.id)
      end

      it 'answers a missing UUID with the same literal status and body' do
        expect_refusal(verb, suffix, payload, id: SecureRandom.uuid)
      end

      context 'without any project access' do
        let(:project_access) { false }

        it 'conceals the ticket despite the token reaching its project' do
          expect_refusal(verb, suffix, payload, id: ticket.id)
        end
      end

      context 'with an all-organisations token' do
        let(:all_organisations) { true }
        let(:token_organisations) { [] }

        it 'still applies ticket read permissions' do
          expect_refusal(verb, suffix, payload, id: ticket.id)
        end
      end

      context 'as an account admin without project grants' do
        let(:admin) { true }
        let(:project_access) { false }

        it 'finds and explicitly authorizes the readable ticket before the action' do
          expect_any_instance_of(TicketPolicy).to receive(:show?).and_call_original
          before = domain_state
          request_ticket(verb, suffix, payload)
          expect(response).to have_http_status(verb == :post ? :created : :ok)
          after = domain_state
          if verb == :patch
            expect(after.first.fetch('custom_attributes').fetch('status')).to eq('closed')
          elsif verb == :post
            key = suffix == '/posts' ? 1 : 2
            expect(after[key]).to eq(before[key] + 1)
            expect(response.parsed_body.dig('data', 'ticket_id')).to eq(ticket.id)
          else
            expect(after).to eq(before)
          end
        end

        context 'with an excluded project' do
          let(:project_scopes) { { organisation => [create(:project, organisation: organisation)] } }

          it 'does not let admin rights bypass the project restriction' do
            expect_refusal(verb, suffix, payload, id: ticket.id)
          end
        end

        context 'with an empty selected-project list' do
          let(:project_scopes) { { organisation => [] } }

          it 'treats an empty project list as no access rather than all projects' do
            expect_refusal(verb, suffix, payload, id: ticket.id)
          end
        end

        context 'with an excluded organisation the user still belongs to' do
          let(:other_org) { create(:organisation) }
          let(:token_organisations) do
            member_of(other_org, admin: true)
            [other_org]
          end

          it 'does not let admin rights bypass the organisation restriction' do
            expect_refusal(verb, suffix, payload, id: ticket.id)
          end
        end
      end

      context 'with a ticket from a foreign organisation' do
        it 'returns the same not-found answer' do
          foreign = Prosopite.pause do
            org = create(:organisation)
            ActsAsTenant.with_tenant(org) do
              create(:ticket, organisation: org, project: create(:project, organisation: org), creator: create(:user))
            end
          end
          expect_refusal(verb, suffix, payload, id: foreign.id)
        end
      end

      context 'after membership was deactivated' do
        let(:admin) { true }

        it 'uses the current membership rather than the saved token links' do
          Prosopite.pause { membership.update!(active: false) }
          expect(Pundit).not_to receive(:policy_scope!)
          expect_refusal(verb, suffix, payload, id: ticket.id)
        end
      end

      context 'with a read-only token' do
        let(:read_only) { true }

        it 'conceals unreadable tickets on reads and refuses writes before looking them up' do
          if verb == :get
            expect_refusal(verb, suffix, payload, id: ticket.id)
          else
            expect(Ticket).not_to receive(:where)
            expect(Ticket).not_to receive(:includes)
            expect_refusal(verb, suffix, payload, id: ticket.id, status: :forbidden, error: 'forbidden', code: 'read_only')
          end
        end

        it 'returns the same answer for a missing UUID' do
          status, error, code = verb == :get ? [:not_found, 'not_found', 'not_found'] : [:forbidden, 'forbidden', 'read_only']
          expect_refusal(verb, suffix, payload, id: SecureRandom.uuid, status: status, error: error, code: code)
        end

        context 'with a readable and writable ticket' do
          let(:ticket_access) { :read_write }

          it 'serves reads and refuses otherwise permitted writes without changes' do
            if verb == :get
              request_ticket(verb, suffix, payload)
              expect(response).to have_http_status(:ok)
            else
              expect_refusal(verb, suffix, payload, id: ticket.id, status: :forbidden, error: 'forbidden',
                                                    code: 'read_only')
            end
          end
        end
      end
    end
  end

  it 'discovers only routing metadata without instantiating an unreadable ticket or project' do
    loaded = []
    queries = []
    records = ->(*args) { loaded << args.last[:class_name] }
    sql = ->(*args) { queries << args.last[:sql] if args.last[:sql].include?('FROM "tickets"') }
    ActiveSupport::Notifications.subscribed(records, 'instantiation.active_record') do
      ActiveSupport::Notifications.subscribed(sql, 'sql.active_record') do
        request_ticket(:get, '', {})
      end
    end
    expect(loaded).not_to include('Ticket', 'Project')
    expect(queries.first).to start_with('SELECT "tickets"."organisation_id", "tickets"."project_id" FROM "tickets"')
    expect(response).to have_http_status(:not_found)
  end

  context 'with a token linked to the requested project' do
    let(:ticket_access) { :read_only }
    let(:project_scopes) { { organisation => [project] } }

    it 'serves the selected ticket using one ticket instantiation' do
      loaded_tickets = 0
      callback = lambda do |*args|
        data = args.last
        loaded_tickets += data[:record_count] if data[:class_name] == 'Ticket'
      end
      ActiveSupport::Notifications.subscribed(callback, 'instantiation.active_record') do
        request_ticket(:get, '', {})
      end
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('data', 'id')).to eq(ticket.id)
      expect(loaded_tickets).to eq(1)
    end
  end

  context 'with a readable ticket and a writable token' do
    let(:ticket_access) { :read_only }
    let(:can_create_time) { false }

    routes.reject { |verb,| verb == :get }.each do |verb, suffix, payload|
      it "keeps action refusal at 403 for #{verb.upcase} #{suffix.presence || 'ticket'}" do
        expect_refusal(verb, suffix, payload, id: ticket.id, status: :forbidden, error: 'forbidden', code: 'forbidden')
      end
    end

    it 'allows booking time without granting ticket write permission' do
      Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) do
          user.time_session_permissions.find_by!(project: project).update!(can_create_own: true)
        end
      end
      before = domain_state
      request_ticket(:post, '/time_sessions', { time_session: { duration_minutes: 30 } })
      expect(response).to have_http_status(:created)
      expect(domain_state.last).to eq(before.last + 1)
      expect(response.parsed_body.dig('data', 'ticket_id')).to eq(ticket.id)
    end

    it 'still scopes child time sessions to those the reader may see' do
      own = Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) do
          other = create(:user)
          create(:membership, user: other, organisation: organisation, role: role, active: true)
          create(:time_session, ticket: ticket, project: project, organisation: organisation, creator: other)
          create(:time_session, ticket: ticket, project: project, organisation: organisation, creator: user)
        end
      end
      request_ticket(:get, '/time_sessions', {})
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch('data').pluck('id')).to eq([own.id])
    end

    it 'does not instantiate unreadable private comments while serving readable comments' do
      readable = Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) do
          create(:post, ticket: ticket, organisation: organisation, user: create(:user), is_private: true, content: 'Private marker')
          create(:post, ticket: ticket, organisation: organisation, user: user, content: 'Public marker')
        end
      end
      loaded_posts = 0
      callback = lambda { |*args|
        data = args.last
        loaded_posts += data[:record_count] if data[:class_name] == 'Post'
      }
      ActiveSupport::Notifications.subscribed(callback, 'instantiation.active_record') do
        request_ticket(:get, '', {})
      end
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('data', 'posts').pluck('id')).to eq([readable.id])
      expect(response.body).not_to include('Private marker')
      expect(loaded_posts).to eq(1)
    end
  end

  context 'with access to two organisations' do
    let(:other_org) { create(:organisation) }
    let(:token_organisations) do
      member_of(other_org, admin: true)
      [organisation, other_org]
    end

    it 'finds the ticket in the reachable second organisation in its own tenant' do
      other_ticket = Prosopite.pause do
        ActsAsTenant.with_tenant(other_org) do
          create(:ticket, organisation: other_org, project: create(:project, organisation: other_org), creator: user)
        end
      end
      request_ticket(:get, '', {}, id: other_ticket.id)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('data', 'id')).to eq(other_ticket.id)
      expect(ActsAsTenant.current_tenant).to be_nil
    end
  end

  context 'with an all-organisations token created before joining another organisation' do
    let(:all_organisations) { true }
    let(:token_organisations) { [] }

    it 'finds a readable ticket in the organisation joined later' do
      later_ticket = Prosopite.pause do
        org = create(:organisation)
        member_of(org, admin: true)
        ActsAsTenant.with_tenant(org) do
          create(:ticket, organisation: org, project: create(:project, organisation: org), creator: user)
        end
      end
      request_ticket(:get, '', {}, id: later_ticket.id)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('data', 'id')).to eq(later_ticket.id)
    end
  end
end
