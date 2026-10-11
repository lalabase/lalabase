# frozen_string_literal: true

require 'rails_helper'

# S3c T3 (assistant plan §4, §8.1): the artefact lane of the full view.
#
# The lane is reachable through an address a person can type, so what is tested
# here is the DOOR, not the layout: an unknown kind, a foreign project and a
# project without a persisted time permission must all end in the same refusal,
# and a reader with the `own` tier must never see a colleague's hours in it.
RSpec.describe 'Assistant artefact lane (S3c T3)', type: :request do
  let(:organisation) do
    create(:organisation, assistant_enabled: true, ai_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef')
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:assistant_role) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation, title: "Assistant #{SecureRandom.hex(3)}")
      create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
      role
    end
  end

  def member_with_assistant_access
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: assistant_role, active: true)
    end
    user
  end

  let(:user) { member_with_assistant_access }
  let(:colleague) { member_with_assistant_access }
  let(:project) { create(:project, organisation: organisation) }

  def permit(view_all:, for_user: user, on: project)
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session_permission, user: for_user, project: on,
                                       can_view_own: true, can_view_all: view_all)
    end
  end

  def book(minutes:, creator: user, description: 'Gebuchte Arbeit')
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session, project: project, organisation: organisation, creator: creator,
                            duration: minutes, description: description, occurred_on: 2.days.ago)
    end
  end

  def get_artefact(params)
    get organisation_assistant_artefact_path(organisation_id: organisation.id, **params)
  end

  describe 'the door' do
    before { sign_in user }

    it 'refuses an unknown kind' do
      get_artefact(kind: 'proposal', project_id: project.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.organisations.assistant_artefacts.unavailable.title'))
    end

    it 'refuses a kind that is missing entirely' do
      get_artefact(project_id: project.id)

      expect(response.body).to include(I18n.t('views.organisations.assistant_artefacts.unavailable.title'))
    end

    it 'refuses a project without a persisted time permission' do
      book(minutes: 60, description: 'Geheime Buchung')

      get_artefact(kind: 'report', project_id: project.id)

      expect(response.body).to include(I18n.t('views.organisations.assistant_artefacts.unavailable.title'))
      expect(response.body).not_to include('Geheime Buchung')
    end

    # The permission in the OTHER organisation is what makes this example about
    # the tenant border. Without it a reader with no rights anywhere would be
    # refused for the ordinary reason and the border itself would stay untested
    # (found by a mutation probe: a tenant-free Project.find_by kept this green).
    it 'answers a project of another organisation exactly like an unknown kind' do
      other_org = create(:organisation)
      other_project = nil
      ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        create(:membership, user: user, organisation: other_org, active: true)
        create(:time_session_permission, user: user, project: other_project,
                                         can_view_own: true, can_view_all: true)
        create(:time_session, project: other_project, organisation: other_org, creator: user,
                              duration: 45, description: 'Fremde Buchung', occurred_on: 2.days.ago)
      end

      get_artefact(kind: 'report', project_id: other_project.id)

      expect(response.body).to include(I18n.t('views.organisations.assistant_artefacts.unavailable.title'))
      expect(response.body).not_to include('Fremde Buchung')
    end

    it 'refuses a report without a project at all' do
      get_artefact(kind: 'report')

      expect(response.body).to include(I18n.t('views.organisations.assistant_artefacts.unavailable.title'))
    end

    # Defense in depth, the two gates apart: the door of the assistant (may you
    # use it here at all) and the door of the KIND (may you see these numbers).
    # A single example that closes both would stay green if one of them went.
    it 'refuses a member whose assistant gate is closed' do
      plain = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, organisation: organisation, title: "Plain #{SecureRandom.hex(3)}", is_default: true)
        create(:membership, user: plain, organisation: organisation, role: role, active: true)
        create(:time_session_permission, user: plain, project: project,
                                         can_view_own: true, can_view_all: true)
      end
      sign_in plain

      get_artefact(kind: 'report', project_id: project.id)

      expect(response).to have_http_status(:forbidden).or have_http_status(:redirect)
    end
  end

  describe 'the report' do
    before { sign_in user }

    it 'shows the rows and the totals for a reader who may see all hours' do
      permit(view_all: true)
      book(minutes: 90, description: 'Meine Buchung')
      book(minutes: 30, creator: colleague, description: 'Buchung der Kollegin')

      get_artefact(kind: 'report', project_id: project.id)

      expect(response.body).to include('Meine Buchung')
      expect(response.body).to include('Buchung der Kollegin')
      expect(response.body).to include('02:00')
    end

    it 'hides a colleague booking from a reader with the own tier' do
      permit(view_all: false)
      book(minutes: 90, description: 'Meine Buchung')
      book(minutes: 30, creator: colleague, description: 'Buchung der Kollegin')

      get_artefact(kind: 'report', project_id: project.id)

      expect(response.body).to include('Meine Buchung')
      expect(response.body).not_to include('Buchung der Kollegin')
      expect(response.body).to include(I18n.t('views.organisations.assistant_artefacts.report.own_only'))
    end

    # The header is rendered BEFORE any row is, so an id resolved to a name there
    # would answer exactly the question the rows refuse to answer. Set up so that
    # not a single row is visible: own tier, filtered to somebody else.
    it 'names nobody when a creator filter points at a person whose rows stay hidden' do
      hidden = member_with_assistant_access
      hidden.update!(first_name: 'Verdeckte', last_name: 'Kollegin')
      permit(view_all: false)
      book(minutes: 30, creator: hidden, description: 'Buchung der Kollegin')

      get_artefact(kind: 'report', project_id: project.id, creator_id: hidden.id)

      expect(response.body).not_to include('Verdeckte Kollegin')
      expect(response.body).not_to include('Buchung der Kollegin')
      expect(response.body).to include(I18n.t('views.organisations.assistant_artefacts.report.filters.one_person'))
    end

    it 'says how much of the list it is showing, with the real numbers' do
      stub_const('Assistant::Panels::TimeReport::ROW_LIMIT', 2)
      permit(view_all: true)
      3.times { |i| book(minutes: 30, description: "Buchung #{i}") }

      get_artefact(kind: 'report', project_id: project.id)

      expect(response.body).to include(
        I18n.t('views.organisations.assistant_artefacts.report.truncated', shown: 2, total: 3)
      )
      # The sums stay complete while the list is short: that is the whole promise.
      expect(response.body).to include('01:30')
    end

    it 'refuses an anonymous request before it renders anything' do
      sign_out user
      book(minutes: 60, description: 'Geheime Buchung')

      get_artefact(kind: 'report', project_id: project.id)

      expect(response).to have_http_status(:redirect)
      expect(response.body).not_to include('Geheime Buchung')
    end

    it 'offers the way out into the time list with the same filters' do
      permit(view_all: true)
      book(minutes: 60)

      get_artefact(kind: 'report', project_id: project.id, start_date: '2020-01-01')

      expect(response.body).to include(I18n.t('views.organisations.assistant_artefacts.report.open_in_list'))
      expect(response.body).to include('start_date=2020-01-01')
    end
  end
end
