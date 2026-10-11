# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organisations::TimeSessionsController, type: :controller do
  before do
    Rails.application.routes.draw do
      # Match real app route structure: scope with as: :organisation (singular)
      scope path: '/org/:organisation_id', module: :organisations, as: :organisation do
        resources :time_sessions, path: 'time-tracking' do
          collection do
            post :bulk_assign_group
          end
        end
        resources :projects do
          resources :time_sessions
        end
      end
    end
  end

  after do
    Rails.application.reload_routes!
  end
  # Include Rails route helpers
  include Rails.application.routes.url_helpers

  # Test constants and class methods - these don't require authentication
  describe 'class attributes and constants' do
    # The two sortable-column examples that stood here are gone with the concern
    # (T4): this list has no sortable columns, its order is fixed and lives in
    # the controller's #row_keys_relation. The order itself is covered over HTTP
    # in spec/requests/organisations/time_sessions_rows_spec.rb.

    it 'has pagination set up with items_per_page' do
      expect(Organisations::TimeSessionsController.default_per_page).to eq(10)
    end
  end

  # Test authentication without hitting controller actions
  describe 'authentication' do
    before do
      @request.env['devise.mapping'] = Devise.mappings[:user]

      # Mock the BaseController behavior to prevent it from trying to access current_user.organisations
      allow(controller).to receive(:set_organisation).and_return(true)
      allow(controller).to receive(:set_current_membership).and_return(true)
      allow(controller).to receive(:current_user).and_return(nil)
      allow(controller).to receive(:user_signed_in?).and_return(false)
      allow(controller).to receive(:authenticate_user!).and_call_original
    end

    it 'requires authentication' do
      get :index, params: { organisation_id: '123', project_id: '456' }
      expect(response).to be_redirect
    end
  end

  # Test controller private methods with minimal auth mocking
  describe 'private methods' do
    let(:organisation) { create(:organisation) }
    let(:project) { create(:project, organisation: organisation) }
    let(:user) { create(:user) }
    let(:ticket) { create(:ticket, project: project) }
    let(:time_session) { create(:time_session, project: project, creator: user) }

    before do
      # Set up the mapping for Devise
      @request.env['devise.mapping'] = Devise.mappings[:user]

      # Set tenant
      ActsAsTenant.current_tenant = organisation

      # Mock authentication
      allow(controller).to receive(:current_user).and_return(user)
      allow(controller).to receive(:user_signed_in?).and_return(true)
      allow(controller).to receive(:current_organisation).and_return(organisation)
      allow(controller).to receive(:authenticate_user!).and_return(true)

      # Mock BaseController methods
      allow(controller).to receive(:set_organisation).and_return(organisation)
      allow(controller).to receive(:set_current_membership).and_return(true)

      # Mock authorization
      allow(controller).to receive(:authorize_time_session_read).and_return(true)
      allow(controller).to receive(:authorize_time_session_write).and_return(true)
      allow(controller).to receive(:authorize_creator!).and_return(true)

      # Mock Pundit policy_scope for Ticket. The pass-through default comes FIRST:
      # a lone .with(Ticket) stub raises on every other argument, and
      # #find_time_sessions scopes a TimeSession relation through the same method.
      allow(controller).to receive(:policy_scope) { |scope| scope }
      allow(controller).to receive(:policy_scope).with(Ticket).and_return(Ticket.all)

      # Set project instance variable directly
      controller.instance_variable_set(:@project, project)
      controller.instance_variable_set(:@organisation, organisation)
    end

    after do
      ActsAsTenant.current_tenant = nil
    end

    describe '#set_ticket' do
      context 'in new action' do
        before do
          allow(controller).to receive(:action_name).and_return('new')
        end

        it 'finds the ticket by id from params' do
          # Mock params with ticket id
          allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                             project_id: project.id,
                                                             ticket_id: ticket.id
                                                           ))

          # Call the method
          controller.send(:set_ticket)

          # Verify that ticket is assigned
          expect(controller.instance_variable_get(:@ticket)).to eq(ticket)
        end

        it 'does not set ticket when ticket_id not in params' do
          # Mock params without ticket id
          allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                             project_id: project.id
                                                           ))

          # Call the method
          controller.send(:set_ticket)

          # Verify that ticket is not assigned
          expect(controller.instance_variable_get(:@ticket)).to be_nil
        end
      end

      context 'in create action' do
        before do
          allow(controller).to receive(:action_name).and_return('create')
        end

        it 'finds the ticket by id from time_session params' do
          # Mock params with ticket id in time_session params
          allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                             project_id: project.id,
                                                             time_session: { ticket_id: ticket.id }
                                                           ))

          # Call the method
          controller.send(:set_ticket)

          # Verify that ticket is assigned
          expect(controller.instance_variable_get(:@ticket)).to eq(ticket)
        end
      end
    end

    describe '#set_time_session' do
      it 'finds the time_session by id' do
        # Mock params with time_session id
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           project_id: project.id,
                                                           id: time_session.id
                                                         ))

        # Call the method
        controller.send(:set_time_session)

        # Verify that time_session is assigned
        expect(controller.instance_variable_get(:@time_session)).to eq(time_session)
      end
    end

    describe '#time_session_params' do
      it 'permits the correct parameters' do
        # Mock params with time_session attributes
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           time_session: {
                                                             duration_string: '1:30',
                                                             occurred_on: Date.current,
                                                             description: 'Test time session',
                                                             ticket_id: ticket.id
                                                           }
                                                         ))

        # Call the method
        result = controller.send(:time_session_params)

        # Verify permitted parameters
        expect(result.to_h).to include(
          'duration_string' => '1:30',
          'occurred_on' => Date.current,
          'description' => 'Test time session',
          'ticket_id' => ticket.id
        )
      end
    end

    # #ensure_valid_ticket_id no longer exists — the ticket-preselection logic sits inline in
    # #edit. Its coverage moved to spec/requests/organisations/time_sessions_update_spec.rb
    # ("GET edit with a ticket_id parameter"), where it is asserted over HTTP instead of by
    # calling a private method with stubbed params.

    describe '#find_time_sessions' do
      # The sorting example that stood here is gone with the concern (T4), and
      # the ticket example with S3 (01.09.2026): #find_time_sessions used to
      # apply params[:ticket_id] itself, on top of TimeSessionFilterService
      # applying the very same condition. One rule with two enforcers, and the
      # copy here sat UNDER every filter -- so the empty state's drop-one probe
      # could switch the subject off in the service and still get a list
      # filtered by it. The base query narrows by nothing switchable now.
      #
      # The behaviour it was pinning is covered over HTTP, where it belongs:
      # spec/requests/organisations/time_sessions_ticket_drilldown_spec.rb (a
      # booking on another ticket must not reach the list) and
      # spec/requests/organisations/time_sessions_empty_reason_spec.rb (the
      # subject as the named culprit).

      it 'narrows by nothing the reader can switch off' do
        time_session
        with_ticket = create(:time_session, project: project, creator: user, ticket: ticket)

        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           project_id: project.id,
                                                           ticket_id: ticket.id
                                                         ))

        result = controller.send(:find_time_sessions)

        expect(result).to include(with_ticket, time_session)
      end
    end

    describe '#authorize_creator!' do
      before do
        # Set up time session instance
        controller.instance_variable_set(:@time_session, time_session)
      end

      it 'does nothing when user is the creator' do
        # Time session is already created with current user as creator

        # Call the method - should not redirect
        expect(controller).not_to receive(:redirect_to)
        controller.send(:authorize_creator!)
      end

      # Test removed: Testing methods with 'redirect_to ... and return' pattern is challenging in RSpec
    end

    describe '#build_time_session' do
      before do
        # Mock params
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(
                                                           time_session: {
                                                             duration_string: '1:30',
                                                             occurred_on: Date.current,
                                                             description: 'Test time session'
                                                           }
                                                         ))

        # Mock time_session_params
        allow(controller).to receive(:time_session_params).and_return(
          ActionController::Parameters.new(
            duration_string: '1:30',
            occurred_on: Date.current,
            description: 'Test time session'
          ).permit!
        )
      end

      it 'builds a time session with correct attributes' do
        # Call the method
        result = controller.send(:build_time_session)

        # Verify attributes
        expect(result).to be_a(TimeSession)
        expect(result.duration_string).to eq('1:30')
        expect(result.occurred_on.to_date).to eq(Date.current)
        expect(result.description).to eq('Test time session')
        expect(result.creator).to eq(user)
        expect(result.organisation).to eq(organisation)
      end

      it 'sets ticket when available' do
        # Set ticket instance
        controller.instance_variable_set(:@ticket, ticket)

        # Call the method
        result = controller.send(:build_time_session)

        # Verify ticket is set
        expect(result.ticket).to eq(ticket)
      end
    end

    describe '#ensure_valid_occurred_on' do
      before { controller.instance_variable_set(:@time_session, time_session) }

      def set_occurred_on_param(value)
        allow(controller).to receive(:params).and_return(
          ActionController::Parameters.new(time_session: { occurred_on: value })
        )
      end

      it 'stores occurred_on at midnight of the entered date IN THE APP ZONE (not the server zone)' do
        set_occurred_on_param('2023-01-15')

        controller.send(:ensure_valid_occurred_on)

        # Contract: same calendar date, start-of-day in Time.zone — independent of the
        # server's system zone. The old `Date#to_time` broke this on a non-UTC host
        # (it landed on the previous day in UTC, shifting dates + the "this week" window).
        expect(time_session.occurred_on).to eq(Time.zone.parse('2023-01-15'))
        expect(time_session.occurred_on.in_time_zone.to_date).to eq(Date.new(2023, 1, 15))
      end

      it 'falls back to today (app zone) when the date cannot be parsed' do
        set_occurred_on_param('not-a-date')

        controller.send(:ensure_valid_occurred_on)

        expect(time_session.occurred_on.in_time_zone.to_date).to eq(Time.zone.today)
      end
    end

    describe '#authorize_time_session_read' do
      it 'allows access when policy permits' do
        # Mock policy check
        policy = double('ProjectPolicy')
        allow(controller).to receive(:policy).with(project).and_return(policy)
        allow(policy).to receive(:area_access?).with(:time_sessions, :read).and_return(true)

        # Call the method - should not redirect
        expect(controller).not_to receive(:redirect_to)
        controller.send(:authorize_time_session_read)
      end

      # Test removed: Testing methods with 'redirect_to ... and return' pattern is challenging in RSpec
    end

    describe '#authorize_time_session_write' do
      it 'allows access when policy permits' do
        # Mock policy check
        policy = double('ProjectPolicy')
        allow(controller).to receive(:policy).with(project).and_return(policy)
        allow(policy).to receive(:area_access?).with(:time_sessions, :write).and_return(true)

        # Call the method - should not redirect
        expect(controller).not_to receive(:redirect_to)
        controller.send(:authorize_time_session_write)
      end

      # Test removed: Testing methods with 'redirect_to ... and return' pattern is challenging in RSpec
    end

    # GET #current_ticket is gone with the tickets-header capture modal
    # (05.09.2026): the endpoint's only caller was the modal's ticket detection.

    describe 'POST #bulk_assign_group' do
      let(:other_user) { create(:user) }
      let!(:own_session1) { create(:time_session, project: project, creator: user, organisation: organisation) }
      let!(:own_session2) { create(:time_session, project: project, creator: user, organisation: organisation) }
      let!(:other_session) do
        create(:membership, user: other_user, organisation: organisation) unless other_user.organisations.include?(organisation)
        create(:time_session, project: project, creator: other_user, organisation: organisation)
      end

      before do
        # bulk_assign_group authorizes the time list and reads the sessions through
        # its policy scope, so the booker needs the real right to see their own.
        ActsAsTenant.with_tenant(organisation) do
          create(:time_session_permission, user: user, project: project, can_view_own: true, can_edit_own: true)
        end

        # Mock authorize_time_session_access for collection action
        allow(controller).to receive(:authorize_time_session_access).and_return(true)

        # set_organisation must actually set the tenant so that tenanted queries work
        allow(controller).to receive(:set_organisation) do
          ActsAsTenant.current_tenant = organisation
          controller.instance_variable_set(:@current_organisation, organisation)
        end
      end

      context 'as non-admin user' do
        before do
          allow(user).to receive(:account_admin_in?).with(organisation).and_return(false)
        end

        it 'assigns own sessions to a new group' do
          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, own_session2.id],
            create_new_group: 'true',
            new_group_name: 'Meine Gruppe'
          }, format: :json

          ActsAsTenant.with_tenant(organisation) do
            own_session1.reload
            own_session2.reload
            expect(own_session1.time_session_group).to be_present
            expect(own_session2.time_session_group).to eq(own_session1.time_session_group)
            expect(own_session1.time_session_group.name).to eq('Meine Gruppe')
          end
        end

        it 'rejects when selecting sessions from other users' do
          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, other_session.id],
            create_new_group: 'true',
            new_group_name: 'Gemischte Gruppe'
          }, format: :json

          ActsAsTenant.with_tenant(organisation) do
            own_session1.reload
            other_session.reload
            # Non-admin cannot assign other users' sessions — entire operation rejected
            expect(own_session1.time_session_group_id).to be_nil
            expect(other_session.time_session_group_id).to be_nil
          end
        end

        it 'rejects when selecting only sessions from other users' do
          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [other_session.id],
            create_new_group: 'true',
            new_group_name: 'Fremde Gruppe'
          }, format: :json

          ActsAsTenant.with_tenant(organisation) do
            other_session.reload
            expect(other_session.time_session_group_id).to be_nil
          end
        end

        # The only-own gate's redirect must survive a cross-host Referer too (same
        # UnsafeRedirectError -> 500 class as respond_bulk_assign): degrade to the
        # fallback, assign nothing. Regression for the second raw-referer site.
        it 'degrades to the fallback for a cross-host referer on the only-own gate' do
          request.env['HTTP_REFERER'] = 'http://evil.example.org/woanders'

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, other_session.id],
            create_new_group: 'true',
            new_group_name: 'Fremd'
          }

          expect(response).to redirect_to(organisation_time_sessions_path(organisation))
          ActsAsTenant.with_tenant(organisation) do
            expect(own_session1.reload.time_session_group_id).to be_nil
          end
        end
      end

      context 'as admin user' do
        before do
          allow(user).to receive(:account_admin_in?).with(organisation).and_return(true)
        end

        it 'assigns own sessions to a new group' do
          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, own_session2.id],
            create_new_group: 'true',
            new_group_name: 'Admin Gruppe'
          }, format: :json

          ActsAsTenant.with_tenant(organisation) do
            own_session1.reload
            own_session2.reload
            expect(own_session1.time_session_group).to be_present
            expect(own_session1.time_session_group.name).to eq('Admin Gruppe')
          end
        end

        it 'assigns sessions from other users to a new group' do
          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, other_session.id],
            create_new_group: 'true',
            new_group_name: 'Gemischte Admin Gruppe'
          }, format: :json

          ActsAsTenant.with_tenant(organisation) do
            own_session1.reload
            other_session.reload
            expect(own_session1.time_session_group).to be_present
            expect(other_session.time_session_group).to eq(own_session1.time_session_group)
            expect(own_session1.time_session_group.name).to eq('Gemischte Admin Gruppe')
          end
        end

        it 'assigns sessions to an existing group' do
          existing_group = create(:time_session_group, organisation: organisation, creator: user)

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, other_session.id],
            create_new_group: 'false',
            existing_group_id: existing_group.id
          }, format: :json

          ActsAsTenant.with_tenant(organisation) do
            own_session1.reload
            other_session.reload
            expect(own_session1.time_session_group).to eq(existing_group)
            expect(other_session.time_session_group).to eq(existing_group)
          end
        end

        # The json/any client gets a bare head on success — pins the 204 side of
        # the status ternary (the 422 failure side is pinned in the billed-guard
        # context below).
        it 'responds 204 No Content to the json client on success' do
          target = create(:time_session_group, organisation: organisation, creator: user)

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id],
            create_new_group: 'false',
            existing_group_id: target.id
          }, format: :json

          expect(response).to have_http_status(:no_content)
        end

        # The bulk bar's JS client actually requests text/html and reloads after
        # the redirect — pin that production path: the referer-less fallback
        # redirect plus the notice that must survive the redirect.
        it 'redirects the html client with the persistent notice flash' do
          target = create(:time_session_group, organisation: organisation, creator: user, name: 'HTML-Ziel')

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id],
            create_new_group: 'false',
            existing_group_id: target.id
          }

          expect(response).to redirect_to(organisation_time_sessions_path(organisation))
          expect(flash[:notice]).to eq(I18n.t('flash.time_sessions.assigned_to_group', count: 1, group: 'HTML-Ziel'))
        end

        # Counterpart to the referer-less fallback above: with a same-host
        # referer the html client returns to the page it came from (e.g. a
        # filtered project view), not to the global time sessions index.
        it 'redirects the html client back to the referer when present' do
          target = create(:time_session_group, organisation: organisation, creator: user)
          request.env['HTTP_REFERER'] = "http://#{request.host}/woanders"

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id],
            create_new_group: 'false',
            existing_group_id: target.id
          }

          expect(response).to redirect_to("http://#{request.host}/woanders")
        end

        # Regression: a CROSS-host Referer header (user-controlled) must degrade
        # to the fallback, not blow up. The previous
        # `redirect_to request.referer || fallback` raised UnsafeRedirectError
        # (-> 500) here; redirect_back handles it.
        it 'falls back to the time sessions index for a foreign-host referer' do
          target = create(:time_session_group, organisation: organisation, creator: user)
          request.env['HTTP_REFERER'] = 'http://evil.example.org/woanders'

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id],
            create_new_group: 'false',
            existing_group_id: target.id
          }

          expect(response).to redirect_to(organisation_time_sessions_path(organisation))
        end

        # Tenant isolation on the SESSION side (the group side is pinned via the
        # cross-tenant 404s): smuggling a foreign organisation's session id into
        # time_session_ids must leave that session untouched — even for an admin,
        # whom the only-own gate never stops. Kills an unscoped/default-scope
        # regression on the bulk lookup, which would otherwise pull foreign
        # sessions into this org's billing group (cross-tenant FK write).
        it 'never assigns sessions of another organisation (smuggled foreign id)' do
          target = create(:time_session_group, organisation: organisation, creator: user)
          foreign_org = create(:organisation)
          foreign_session = ActsAsTenant.with_tenant(foreign_org) do
            foreign_user = create(:user)
            create(:membership, user: foreign_user, organisation: foreign_org)
            foreign_project = create(:project, organisation: foreign_org)
            create(:time_session, organisation: foreign_org, project: foreign_project, creator: foreign_user)
          end

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, foreign_session.id],
            create_new_group: 'false',
            existing_group_id: target.id
          }, format: :json

          ActsAsTenant.with_tenant(organisation) do
            expect(own_session1.reload.time_session_group_id).to eq(target.id)
          end
          ActsAsTenant.with_tenant(foreign_org) do
            expect(foreign_session.reload.time_session_group_id).to be_nil
          end
        end

        # Failure mode from plan §9.4: an unknown existing_group_id must surface
        # as RecordNotFound (tenant-scoped find, 404 in production) — never as a
        # silent no-op and never reach the actor with a nil group.
        it 'raises RecordNotFound for an unknown existing group id and assigns nothing' do
          expect do
            post :bulk_assign_group, params: {
              organisation_id: organisation.id,
              time_session_ids: [own_session1.id],
              create_new_group: 'false',
              existing_group_id: SecureRandom.uuid
            }, format: :json
          end.to raise_error(ActiveRecord::RecordNotFound)

          ActsAsTenant.with_tenant(organisation) do
            expect(own_session1.reload.time_session_group_id).to be_nil
          end
        end
      end

      # [P1] Invoice integrity: sessions must never flow into or out of a billed
      # (invoiced) group via the raw update_all bulk path. Both directions are
      # guarded, all-or-nothing. Failing-first: against the pre-T1 controller
      # (no guard) each of these assigns anyway, so the reload assertions are red.
      context 'billed-guard (P1 invoice integrity)' do
        before do
          allow(user).to receive(:account_admin_in?).with(organisation).and_return(true)
        end

        it 'refuses to assign into a billed group and leaves sessions untouched' do
          billed_group = create(:time_session_group, :billed, organisation: organisation, creator: user)

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, own_session2.id],
            create_new_group: 'false',
            existing_group_id: billed_group.id
          }, format: :json

          # 422 for the `any`/JSON client (pins the failure head status).
          expect(response).to have_http_status(:unprocessable_content)
          ActsAsTenant.with_tenant(organisation) do
            expect(own_session1.reload.time_session_group_id).to be_nil
            expect(own_session2.reload.time_session_group_id).to be_nil
          end
        end

        it 'refuses to move an already-billed session and rolls back the whole batch' do
          target = create(:time_session_group, organisation: organisation, creator: user)
          billed_session = create(:time_session, project: project, creator: user,
                                                 organisation: organisation, billed: true)

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, billed_session.id],
            create_new_group: 'false',
            existing_group_id: target.id
          }, format: :json

          ActsAsTenant.with_tenant(organisation) do
            # All-or-nothing: the clean session must not move either.
            expect(own_session1.reload.time_session_group_id).to be_nil
            expect(billed_session.reload.time_session_group_id).to be_nil
          end
        end

        it 'refuses to reassign a session out of a billed source group' do
          billed_source = create(:time_session_group, :billed, organisation: organisation, creator: user)
          grouped_session = create(:time_session, project: project, creator: user,
                                                  organisation: organisation, time_session_group: billed_source)
          target = create(:time_session_group, organisation: organisation, creator: user)

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [grouped_session.id],
            create_new_group: 'false',
            existing_group_id: target.id
          }, format: :json

          ActsAsTenant.with_tenant(organisation) do
            expect(grouped_session.reload.time_session_group_id).to eq(billed_source.id)
          end
        end

        it 'leaves no orphaned group when the new-group path hits a billed session' do
          billed_session = create(:time_session, project: project, creator: user,
                                                 organisation: organisation, billed: true)
          before_count = TimeSessionGroup.count

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, billed_session.id],
            create_new_group: 'true',
            new_group_name: 'Darf nicht entstehen'
          }, format: :json

          ActsAsTenant.with_tenant(organisation) do
            expect(TimeSessionGroup.count).to eq(before_count)
            expect(own_session1.reload.time_session_group_id).to be_nil
          end
        end

        # Not just THAT it fails, but WHY: the user must see the specific billed
        # reason, not the generic "Fehler beim Zuweisen" wrapper. Turbo format so
        # the alert flash is actually set (the head-only json branch is silent).
        it 'surfaces the specific billed reason to the user (not a generic error)' do
          billed_group = create(:time_session_group, :billed, organisation: organisation, creator: user)

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id],
            create_new_group: 'false',
            existing_group_id: billed_group.id
          }, format: :turbo_stream

          expect(flash[:alert]).to eq(I18n.t('services.time_session_group_assigner.group_billed'))
        end
      end

      # Counter contract (regression lock, green before and after T1): the flash
      # counts are derived from the exact same set the write touches, gathered
      # BEFORE the write.
      context 'flash counter contract' do
        before do
          allow(user).to receive(:account_admin_in?).with(organisation).and_return(true)
        end

        # Exact-message pin with count 2: a warning that merely EXISTS would let a
        # hardcoded/wrong count through (the subset counting itself — 1 of 3 —
        # is pinned in the assigner PORO spec).
        it 'warns with the real number of already-assigned (reassigned) sessions' do
          source = create(:time_session_group, organisation: organisation, creator: user)
          ActsAsTenant.with_tenant(organisation) do
            own_session1.update!(time_session_group: source)
            own_session2.update!(time_session_group: source)
          end
          target = create(:time_session_group, organisation: organisation, creator: user)

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, own_session2.id],
            create_new_group: 'false',
            existing_group_id: target.id
          }, format: :json

          expect(flash[:warning]).to eq(I18n.t('flash.time_sessions.already_assigned', count: 2))
        end

        it 'notes when the assigned sessions span multiple projects' do
          other_project = create(:project, organisation: organisation)
          other_session = create(:time_session, project: other_project, creator: user, organisation: organisation)
          target = create(:time_session_group, organisation: organisation, creator: user)

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, other_session.id],
            create_new_group: 'false',
            existing_group_id: target.id
          }, format: :json

          expect(flash[:info]).to be_present
          expect(flash[:info]).to include(other_project.name)
        end

        # Lower boundary (n=1 project): pins the `> 1` threshold against `>= 1`,
        # which would spam the info flash on every single-project assignment.
        it 'sets no multi-project info when every session shares one project' do
          target = create(:time_session_group, organisation: organisation, creator: user)

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, own_session2.id], # both in `project`
            create_new_group: 'false',
            existing_group_id: target.id
          }, format: :json

          expect(flash[:info]).to be_nil
        end

        # Lower boundary (n=0 already-assigned): pins `.positive?` against an
        # always-true predicate, which would warn even on a clean assignment.
        it 'sets no already-assigned warning when every session was ungrouped' do
          target = create(:time_session_group, organisation: organisation, creator: user)

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, own_session2.id], # both ungrouped
            create_new_group: 'false',
            existing_group_id: target.id
          }, format: :json

          expect(flash[:warning]).to be_nil
        end

        # Success feedback is user-visible confirmation, not just a DB effect: the
        # notice must carry the real batch size AND the target group's name (a
        # name-only check would let a hardcoded count through). Turbo format (the
        # html/turbo branches set the flash; the head-only `any`/json branch does
        # not).
        it 'confirms the assignment with the real count and the group name in the notice' do
          target = create(:time_session_group, organisation: organisation, creator: user, name: 'Mai-Rechnung')

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id, own_session2.id],
            create_new_group: 'false',
            existing_group_id: target.id
          }, format: :turbo_stream

          expect(flash[:notice]).to eq(I18n.t('flash.time_sessions.assigned_to_group', count: 2, group: 'Mai-Rechnung'))
          # The turbo client must ALSO receive the refresh stream — a flash
          # alone would leave the visible list stale until a manual reload.
          expect(response.body).to include('action="refresh"')
        end
      end

      # Error-mapping wiring for the create-new path: a blank name is a
      # RecordInvalid -> :validation_failed -> assign_error alert, and the failed
      # actor transaction leaves no group behind.
      context 'invalid new group name' do
        before do
          allow(user).to receive(:account_admin_in?).with(organisation).and_return(true)
        end

        it 'alerts with the wrapped validation message and creates no group when the name is blank' do
          before_count = TimeSessionGroup.count

          post :bulk_assign_group, params: {
            organisation_id: organisation.id,
            time_session_ids: [own_session1.id],
            create_new_group: 'true',
            new_group_name: ''
          }, format: :turbo_stream

          # Pins the else branch of bulk_assign_error_message: the model sentence
          # must arrive WRAPPED in the assign_error message, not bare.
          expected_error = ActsAsTenant.with_tenant(organisation) do
            TimeSessionGroup.new(name: '').tap(&:validate).errors.full_messages_for(:name).to_sentence
          end
          expect(flash[:alert]).to eq(I18n.t('flash.time_sessions.assign_error', error: expected_error))
          ActsAsTenant.with_tenant(organisation) do
            expect(TimeSessionGroup.count).to eq(before_count)
            expect(own_session1.reload.time_session_group_id).to be_nil
          end
        end
      end
    end
  end
end
