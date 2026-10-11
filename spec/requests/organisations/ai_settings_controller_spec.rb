# frozen_string_literal: true

# What: Request spec for Organisations::AiSettingsController.
# Type: Request spec — security / cross-tenant isolation.
# Why (philosophy): Regression guard against a confirmed, exploitable
#   cross-tenant gap. The overridden `set_organisation` previously loaded the
#   organisation UNSCOPED (`Organisation.find(params[:organisation_id])`)
#   and did NOT reset the tenant. The policy (`account_admin?`), however, checks
#   against `ActsAsTenant.current_tenant` — and the tenant comes from the session
#   (= the attacker's own org), not from the loaded `@organisation`.
#   This allowed an account_admin of org A, via `params[:organisation_id]`,
#   to read the AI settings of a foreign org B (token/usage/cost leak via #show)
#   and even overwrite its `ai_access_token` via #update (key hijack).
#   This spec MUST be red before the fix and stay green afterwards.
# Contract: Access to /org/:organisation_id/ai_settings (show/update/
#   test_connection) is allowed exclusively to members of org :organisation_id.
#   Non-members receive 404 (no existence leak), not 200/302.

require 'rails_helper'

RSpec.describe 'Organisations::AiSettings cross-tenant isolation', type: :request do
  # Realistic OpenAI token format, so that masked_ai_token would apply too.
  let(:victim_token) { 'sk-victim-org-b-secret-token-1234567890' }

  # org_a = the attacker's organisation; he is account_admin there.
  let(:org_a) { create(:organisation, name: 'Angreifer Org A') }

  # org_b = foreign organisation; the attacker is NOT a member. Holds a
  # secret (ai_access_token) whose leak/overwrite we want to prevent.
  let(:org_b) do
    create(:organisation, name: 'Opfer Org B', ai_provider: 'openai', ai_access_token: victim_token)
  end

  let(:attacker) { create(:user) }

  # account_admin role + active membership ONLY in org_a.
  let!(:attacker_admin_role) do
    ActsAsTenant.with_tenant(org_a) { create(:admin_role, organisation: org_a) }
  end

  let!(:attacker_membership) do
    ActsAsTenant.with_tenant(org_a) do
      create(:membership, user: attacker, organisation: org_a, role: attacker_admin_role, active: true)
    end
  end

  before do
    sign_in attacker
    # Realistic precondition of the attack: the attacker is an active
    # user whose session knows his OWN org (session[:current_organisation_id]).
    # Only then does ApplicationController#load_tenant_from_session resolve the tenant
    # to org_a when a foreign org_b is subsequently requested — without
    # this precondition the request would be redirected to
    # /select_organisation before even reaching the controller, and the bug would stay hidden.
    prime_session_with_own_org!
  end

  def prime_session_with_own_org!
    get organisation_ai_settings_path(organisation_id: org_a.id)
  end

  describe 'GET #show auf eine fremde Org' do
    # Intent: #show must NOT reveal the AI settings (ai_organization_id, masked token,
    # usage/cost) of an org in which the user is not a member.
    it 'liefert 404 statt die fremden AI-Settings zu leaken' do
      get organisation_ai_settings_path(organisation_id: org_b.id)

      expect(response).to have_http_status(:not_found)
    end
  end

  # ⚠️ The write MOVED with S7 (doc/ki_bereich_navigation_plan.md, E6-A): the key form
  # posted to ai_settings#update, it now posts to Organisations::AiConfigurations
  # #update, and the settings route no longer answers PATCH at all. The guard follows
  # the write rather than the URL — a cross-tenant regression spec pointed at a route
  # that 404s for everybody would be green and worthless.
  describe 'PATCH #update auf eine fremde Org (jetzt „Eigene Konfiguration")' do
    # Intent: the write must not overwrite the ai_access_token of a foreign org
    # (key hijack). We check both the HTTP status and
    # the unchanged persistence state — the status alone would not rule out
    # a successful write despite a redirect.
    it 'liefert 404 und lässt das ai_access_token der fremden Org unverändert' do
      patch organisation_ai_configuration_path(organisation_id: org_b.id), params: {
        ai_provider: 'openai',
        ai_access_token: 'sk-attacker-hijacked-token-1234567890',
        ai_organization_id: 'org-attacker'
      }

      expect(response).to have_http_status(:not_found)
      expect(org_b.reload.ai_access_token).to eq(victim_token)
    end

    # The removal door is new with S7 and is the one write that DELETES a key, so it
    # needs the same negative check rather than inheriting trust from its sibling.
    it 'liefert 404 auf „Zugang entfernen" und lässt den fremden Schlüssel stehen' do
      delete organisation_ai_configuration_path(organisation_id: org_b.id)

      expect(response).to have_http_status(:not_found)
      expect(org_b.reload.ai_access_token).to eq(victim_token)
    end

    it 'liefert 404 auf GET, statt das maskierte Token der fremden Org zu zeigen' do
      get organisation_ai_configuration_path(organisation_id: org_b.id)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST #test_connection auf eine fremde Org' do
    # Intent: The third action that uses @organisation must also be
    # membership-scoped — otherwise a side channel would remain open.
    it 'liefert 404 statt die Verbindung der fremden Org zu testen' do
      post test_connection_organisation_ai_settings_path(organisation_id: org_b.id),
           params: { provider: 'openai' }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'Positiv-Gegenprobe: eigene Org' do
    # Intent: The fix must not break legitimate access — the admin must
    # still be able to see the AI settings of his OWN org.
    it 'erlaubt der Admin den Zugriff auf die AI-Settings der eigenen Org' do
      get organisation_ai_settings_path(organisation_id: org_a.id)

      expect(response).to have_http_status(:ok)
    end
  end

  # S3 KI-Kontingent (decision 5A, review 2026-07-12): NO quota-resume hook fires
  # from the chat AI-settings update. The paused work is embeddings (gated on the
  # embedding columns), which chat BYOK cannot un-gate, so a resume here would only
  # no-op. The effective resume triggers are covered elsewhere: the admin budget
  # increase (spec/requests/admin/organisations_spec.rb) and the monthly reset
  # (spec/jobs/ai_quota_monthly_resume_job_spec.rb).
  describe 'no misleading resume hook on chat #update' do
    it 'does NOT enqueue a resume when chat BYOK credentials are saved' do
      expect(AiQuotaResumeJob).not_to receive(:perform_later)

      patch organisation_ai_configuration_path(organisation_id: org_a.id), params: {
        ai_provider: 'openai',
        ai_access_token: 'sk-org-a-own-key-1234567890'
      }

      expect(response).to have_http_status(:redirect)
    end
  end
end
