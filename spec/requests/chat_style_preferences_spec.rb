# frozen_string_literal: true

require 'rails_helper'

# Per-user chat answer-style level (ChatStylePreference): the style pills under
# the chat composer PATCH one dimension to an absolute level.
#
# Intent per test: the write lands on the requesting user's own row in the
# current org only (never another user's, never another org's), the whitelist
# rejects crafted dimension/level params with a 422, and — the property the whole
# UI change rests on — setting a style enqueues NO answer job.
RSpec.describe 'Organisations::ChatStylePreferences', type: :request do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  # The :test adapter is needed for the have_enqueued_job matcher below (the
  # suite default adapter does not support it).
  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = original
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  def pref_in(org, for_user)
    ActsAsTenant.with_tenant(org) { ChatStylePreference.find_by(user: for_user, organisation: org) }
  end

  def set_style(dimension: 'technicality', level: 3, org: organisation)
    patch organisation_chat_style_preference_path(org, dimension: dimension, level: level), as: :turbo_stream
  end

  describe 'PATCH /org/:organisation_id/chat_style_preference' do
    it 'stores the level and re-renders the pill row (turbo_stream)' do
      set_style(dimension: 'technicality', level: 3)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include('chat-style-level')
      # replace_all, so BOTH copies move (panel + page) -- an id could only ever
      # reach the first one in the document.
      expect(response.body).to include('targets=')
      expect(pref_in(organisation, user).technicality).to eq(3)

      # Cohesive block: the re-rendered row actually shows the newly picked step,
      # not just "some frame returned".
      expect(response.body).to include(I18n.t('views.organisations.chats.style_level.technicality.3'))
    end

    it 'writes each dimension independently' do
      set_style(dimension: 'technicality', level: 1)
      set_style(dimension: 'length', level: 3)

      row = pref_in(organisation, user)
      expect(row.technicality).to eq(1)
      expect(row.length).to eq(3) # picking one step must not reset the other
    end

    # THE separation the redesign rests on: a style click is free — it costs no
    # AI quota and does not re-run the previous answer. Regenerating is the
    # explicit, separately gated action on the answer itself.
    it 'enqueues NO answer job' do
      allow(ChatResponseJob).to receive(:perform_later).and_call_original

      expect { set_style }.not_to have_enqueued_job(ChatResponseJob)
    end

    describe 'whitelist (crafted params)' do
      it 'rejects an unknown dimension with 422 and writes nothing' do
        set_style(dimension: 'bogus')

        expect(response).to have_http_status(:unprocessable_content)
        expect(pref_in(organisation, user)).to be_nil
      end

      it 'rejects a real-but-not-settable column with 422' do
        set_style(dimension: 'organisation_id', level: 1)

        expect(response).to have_http_status(:unprocessable_content)
        expect(pref_in(organisation, user)).to be_nil
      end

      # Boundaries n-1 / n / n+1: a widened range would store a level the prompt
      # lookup has no I18n key for.
      it 'rejects level 0 with 422' do
        set_style(level: 0)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'rejects level 4 with 422' do
        set_style(level: 4)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'accepts level 1' do
        set_style(level: 1)
        expect(response).to have_http_status(:ok)
      end
    end

    it 'writes only the requesting user’s row, never another user’s in the same org' do
      other_user = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: other_user, organisation: organisation,
                            role: create(:role, organisation: organisation), active: true)
        create(:chat_style_preference, organisation: organisation, user: other_user, technicality: 1)
      end

      set_style(dimension: 'technicality', level: 3)

      expect(pref_in(organisation, user).technicality).to eq(3)       # mine set
      expect(pref_in(organisation, other_user).technicality).to eq(1) # theirs intact
    end

    it 'writes only the current org’s row, never the same user’s row in another org (cross-tenant)' do
      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        create(:membership, user: user, organisation: other_org,
                            role: create(:admin_role, organisation: other_org), active: true)
        create(:chat_style_preference, organisation: other_org, user: user, technicality: 1)
      end

      set_style(dimension: 'technicality', level: 3)

      expect(pref_in(organisation, user).technicality).to eq(3) # org A set
      expect(pref_in(other_org, user).technicality).to eq(1)    # org B untouched
    end

    it 'redirects an unauthenticated visitor to sign in (no write)' do
      sign_out user
      patch organisation_chat_style_preference_path(organisation, dimension: 'technicality', level: 3)

      expect(response).to have_http_status(:redirect)
      expect(pref_in(organisation, user)).to be_nil
    end
  end
end
