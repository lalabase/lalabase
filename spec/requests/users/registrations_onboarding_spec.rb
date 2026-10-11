# frozen_string_literal: true

# Onboarding entry point on self-registration (doc/onboarding_plan.md, S1):
# the no-token path must produce a (optionally custom-named) organisation via
# the shared bootstrap actor PLUS the seeded tutorial project — while the
# token path must stay seed-free, and a crashing seed must never break the
# signup itself (failure-mode test 18). Also pins the CSRF re-activation (D7):
# the controller used to skip verify_authenticity_token wholesale.
require 'rails_helper'

RSpec.describe 'User registration onboarding', :ci_guard, type: :request do
  let(:valid_params) do
    {
      user: {
        first_name: 'Otto',
        last_name: 'Neuling',
        email: 'otto.neu@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        terms_accepted: '1'
      }
      # Trap params: mandatory on every real submission (BotTrapRequestHelpers).
    }.merge(bot_trap_params)
  end

  def created_user
    User.find_by(email: 'otto.neu@example.com')
  end

  # The system account is an instance-wide singleton the seed lazily creates;
  # pre-creating it keeps the User.count assertions focused on the registrant.
  before { User.system }

  describe 'POST /users without token (evaluator path)' do
    it 'creates org, membership and the seeded tutorial project with assigned tickets' do
      expect { post user_registration_path, params: valid_params }.to change(User, :count).by(1)

      user = created_user
      organisation = user.organisations.first
      expect(organisation).to be_present
      expect(organisation.name).to eq("Otto.neu's Organisation")

      ActsAsTenant.with_tenant(organisation) do
        project = organisation.projects.find_by(system_kind: 'onboarding')
        expect(project).to be_present
        tickets = project.tickets
        expect(tickets.count).to eq(4)
        expect(TicketAssignment.where(ticket: tickets).pluck(:user_id).uniq).to eq([user.id])
      end
    end

    it 'uses the submitted organisation name when given' do
      post user_registration_path,
           params: valid_params.deep_merge(user: { organisation_name: 'Muster GmbH' })

      expect(created_user.organisations.first.name).to eq('Muster GmbH')
    end

    it 'falls back to the email-derived default when the name is blank' do
      post user_registration_path,
           params: valid_params.deep_merge(user: { organisation_name: '   ' })

      expect(created_user.organisations.first.name).to eq("Otto.neu's Organisation")
    end

    # Organisation names are unique across the WHOLE instance, so collisions
    # are a normal Tuesday ("Muster GmbH", second info@… registration). The
    # user must end up with a numbered variant + tutorial — never silently
    # org-less (code-review finding P2-1).
    describe 'organisation name collisions' do
      it 'retries a taken submitted name with a numbered variant and still seeds' do
        create(:organisation, name: 'Muster GmbH')

        post user_registration_path,
             params: valid_params.deep_merge(user: { organisation_name: 'Muster GmbH' })

        organisation = created_user.organisations.first
        expect(organisation.name).to eq('Muster GmbH 2')
        ActsAsTenant.with_tenant(organisation) do
          expect(organisation.projects.where(system_kind: 'onboarding')).to exist
        end
      end

      it 'retries a taken email-derived default the same way' do
        create(:organisation, name: "Otto.neu's Organisation")

        post user_registration_path, params: valid_params

        expect(created_user.organisations.first.name).to eq("Otto.neu's Organisation 2")
      end

      it 'skips already-taken numbered variants' do
        create(:organisation, name: 'Muster GmbH')
        create(:organisation, name: 'Muster GmbH 2')

        post user_registration_path,
             params: valid_params.deep_merge(user: { organisation_name: 'Muster GmbH' })

        expect(created_user.organisations.first.name).to eq('Muster GmbH 3')
      end

      # All or nothing (owner decision D2, 15.09.2026, Actors::CreateSignup): until then
      # this kept a user without an organisation, which nobody could repair from the
      # form. Now nothing is created and the form says so.
      it 'creates nothing and shows the form again when creation ultimately fails' do
        failure = Actors::BaseActor::Result.new(success: false, errors: ['kaputt'])
        allow(Actors::CreateOrganisation).to receive(:call).and_return(failure)

        mails_before = ActionMailer::Base.deliveries.size
        expect { post user_registration_path, params: valid_params }.not_to change(User, :count)
        expect(ActionMailer::Base.deliveries.size).to eq(mails_before) # no confirmation for a rolled-back user

        expect(response).to have_http_status(:unprocessable_content)
        expect(flash[:alert]).to eq(I18n.t('flash.registrations.organisation_creation_failed'))
      end
    end

    # The seed writes German content for the default language_preference —
    # pinned as a contract: if the users.language_preference default flips or
    # the locale resolution in the actor drifts, this breaks.
    it 'seeds German content by default (locale contract)' do
      post user_registration_path, params: valid_params

      organisation = created_user.organisations.first
      ActsAsTenant.with_tenant(organisation) do
        expect(organisation.projects.find_by(system_kind: 'onboarding').name)
          .to eq('Lalabase kennenlernen')
      end
    end

    # The FULL functional block, not just its pieces: signup → seeded
    # assignments → outbox → fanout → inbox rows → rendered inbox page.
    # Catches integration drift that unit specs cannot (e.g. the pipeline
    # suppressing system-actor events, or the inbox view crashing on the
    # membership-less system actor).
    it 'delivers in_app-only assignment notifications and renders the inbox (end-to-end)' do
      # Every job the signup enqueues, and every job those enqueue, run the way
      # the worker runs them (drain_enqueued_jobs). The signup runs without a
      # tenant and a job carries the tenant set when it is enqueued, so this is
      # where a job that forgot to set or look up its tenant fails. Until
      # 2026-10-02 this example called OutboxConsumeJob.perform_now inside
      # without_tenant, which lifted the very requirement the worker trips
      # over: the outbox jobs (and the activity broadcasts, since removed)
      # failed in a real worker while this stayed green.
      with_test_queue_adapter do
        post user_registration_path, params: valid_params
        # Each job looks up its tenant once when it is deserialized. In a
        # worker every job runs on its own; run back to back here, Prosopite
        # would read those lookups as an N+1.
        Prosopite.pause
        drain_enqueued_jobs
        Prosopite.resume
        expect(performed_jobs.map { |job| job[:job] })
          .to include(OutboxConsumeJob, Turbo::Streams::ActionBroadcastJob, Notifications::UnreadSignalsJob)
      end
      user = created_user
      organisation = user.organisations.first

      ActsAsTenant.without_tenant do
        notifications = Notification.where(recipient: user)
        expect(notifications.where(channel: :in_app, event_type: 'ticket_assigned').count).to eq(4)
        expect(notifications.where(channel: :email)).not_to exist
        expect(notifications.where(channel: :in_app).pluck(:actor_id).uniq).to eq([User.system.id])
      end

      # Follow the real post-signup flow (redirect to the org root sets the
      # session tenant) before opening the inbox: it must render the
      # membership-less system actor without blowing up. The inbox itself
      # 302s once to its canonical default filter (state_filters=unread).
      follow_redirect!
      get organisation_notifications_path(organisation)
      expect(response).to have_http_status(:found)
      follow_redirect!
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Lalabase')
    end

    it 'survives a crashing seed: account + organisation exist, no tutorial project, no 500' do
      allow(Actors::SeedOnboarding).to receive(:call).and_raise(StandardError, 'kaputtes YAML')

      expect { post user_registration_path, params: valid_params }.to change(User, :count).by(1)

      expect(response).to have_http_status(:redirect)
      organisation = created_user.organisations.first
      expect(organisation).to be_present
      ActsAsTenant.with_tenant(organisation) do
        expect(organisation.projects.where(system_kind: 'onboarding')).not_to exist
      end
    end
  end

  describe 'GET /users/sign_up with an invitation token' do
    # Regression for the incidental bugfix: this action called the
    # non-existent Invitation#expired? and 500ed for every invited newcomer.
    it 'renders the sign-up form for a fresh invitation' do
      organisation = create(:organisation)
      invitation = ActsAsTenant.with_tenant(organisation) do
        create(:invitation, organisation: organisation, email: 'otto.neu@example.com')
      end

      get new_user_registration_path(token: invitation.token)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="user[terms_accepted]"')
    end
  end

  describe 'POST /users with an invitation token' do
    it 'joins the inviting organisation and does NOT seed a tutorial project' do
      organisation = create(:organisation)
      invitation = ActsAsTenant.with_tenant(organisation) do
        create(:invitation, organisation: organisation, email: 'otto.neu@example.com')
      end

      post user_registration_path, params: valid_params.merge(token: invitation.token)

      user = created_user
      expect(user.organisations).to include(organisation)
      ActsAsTenant.without_tenant do
        expect(Project.where(system_kind: 'onboarding')).not_to exist
      end
    end

    # Expired token = treated like no invitation: the user does NOT join the
    # inviting org and instead gets an own organisation WITH tutorial. Pinned
    # deliberately — if this fallback is ever unwanted, the change must be a
    # conscious decision, not an accident of the out_of_date? gate.
    it 'falls back to an own seeded organisation when the invitation is expired' do
      organisation = create(:organisation)
      invitation = ActsAsTenant.with_tenant(organisation) do
        create(:invitation, organisation: organisation, email: 'otto.neu@example.com', sent_at: 4.days.ago)
      end

      post user_registration_path, params: valid_params.merge(token: invitation.token)

      user = created_user
      expect(user.organisations).not_to include(organisation)
      own_org = user.organisations.first
      expect(own_org).to be_present
      ActsAsTenant.with_tenant(own_org) do
        expect(own_org.projects.where(system_kind: 'onboarding')).to exist
      end
    end

    # The token still opens the form and the gate (invitations are always allowed), but a
    # dead invitation redeems nothing: on a CLOSED instance it must not turn into a
    # self-registration with its own organisation. Until 15.09.2026 it did, because the
    # closed check sat only in the controller's gate, which any token passed.
    it 'does not let an expired invitation open a closed registration' do
      allow(SystemSetting).to receive(:allow_registration?).and_return(false)
      organisation = create(:organisation)
      invitation = ActsAsTenant.with_tenant(organisation) do
        create(:invitation, organisation: organisation, email: 'otto.neu@example.com', sent_at: 4.days.ago)
      end

      expect { post user_registration_path, params: valid_params.merge(token: invitation.token) }
        .not_to change(User, :count)

      expect(response).to redirect_to(new_user_registration_path)
      expect(flash[:alert]).to eq(SystemSetting.registration_disabled_message)
    end
  end

  describe 'CSRF protection (regression, decision D7)' do
    it 'no longer skips verify_authenticity_token' do
      filters = Users::RegistrationsController._process_action_callbacks.map(&:filter)
      expect(filters).to include(:verify_authenticity_token)
    end

    # The callback-presence check above is an introspection tripwire; this one
    # proves the protection actually BITES in the full stack. Request specs
    # normally run with forgery protection off — re-enable it locally.
    context 'with forgery protection enabled (as in production)' do
      around do |example|
        original = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        example.run
      ensure
        ActionController::Base.allow_forgery_protection = original
      end

      # The sharp assertion is the unchanged User.count: under a :null_session
      # strategy the account WOULD still be created (registration needs no
      # session); only :exception actually rejects the forged write. show_exceptions=:rescuable renders
      # the InvalidAuthenticityToken as 422 instead of raising.
      it 'rejects a POST without an authenticity token' do
        expect { post user_registration_path, params: valid_params }
          .not_to change(User, :count)

        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end
end
