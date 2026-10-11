# frozen_string_literal: true

require 'rails_helper'

# S3a T2 (assistant plan §6.1, §12): the org-wide personal thread gets its own
# routes and controllers. The door is ChatPolicy's org branch -- ownership plus
# the §13-2 pair (operator flag + use_assistant), deliberately without any
# project area and without an admin bypass. These specs follow the REQUESTS, not
# the policy: a route that forgets `authorize` would pass every policy spec and
# still leak.
RSpec.describe 'Assistant chats — org-wide personal threads', type: :request do
  include ActiveJob::TestHelper

  # jobs_helper stubs ChatResponseJob.perform_later suite-wide (Redis guard);
  # these specs assert the enqueue, so restore the real method (pattern:
  # save_chat_spec).
  before { allow(ChatResponseJob).to receive(:perform_later).and_call_original }

  # Save/restore around the adapter swap (pattern: chat_style_preferences_spec).
  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original
  end

  # The request cycle swaps the ActsAsTenant tenant; counting AFTER a request
  # therefore re-enters the tenant explicitly.
  def org_thread_count
    ActsAsTenant.with_tenant(organisation) { Chat.org_threads.count }
  end

  let(:organisation) { create(:organisation, assistant_enabled: true, ai_enabled: true) }

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

  let(:owner)    { member_with_assistant_access }
  let(:stranger) { member_with_assistant_access }

  let(:admin_user) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: 'account_admin', organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end

  let!(:owners_thread) do
    ActsAsTenant.with_tenant(organisation) do
      chat = create(:chat, :org_thread, organisation: organisation, user: owner)
      chat.chatposts.first.update!(user: owner, content: 'Wie viele Stunden sind offen?')
      chat
    end
  end

  describe 'POST /assistant_chats (create)' do
    let(:params) { { chat: { chatposts_attributes: [{ content: 'Erste Frage' }] } } }

    it 'creates an org thread owned by the asker and enqueues the first answer' do
      sign_in owner

      expect do
        post organisation_assistant_chats_path(organisation), params: params
      end.to change { org_thread_count }.by(1)

      ActsAsTenant.with_tenant(organisation) do
        chat = Chat.org_threads.order(:created_at).last
        expect(chat.project_id).to be_nil
        expect(chat.user_id).to eq(owner.id)
        expect(chat.chatposts.first.user_id).to eq(owner.id)
        # T4: the thread has no page of its own; the non-Turbo path lands where
        # the panel is and names the thread it should open on.
        expect(response).to redirect_to(
          organisation_root_path(organisation_id: organisation.id, assistant_chat_id: chat.id)
        )
        expect(ChatResponseJob).to have_been_enqueued.with(chat, question_chatpost_id: chat.chatposts.first.id)
      end
    end

    it 'refuses while the operator flag is off' do
      organisation.update!(assistant_enabled: false)
      sign_in owner

      expect do
        post organisation_assistant_chats_path(organisation), params: params
      end.not_to(change { org_thread_count })
      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to be_present
    end

    it 'refuses a member whose role lacks use_assistant' do
      plain = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, organisation: organisation, title: 'Plain', is_default: true)
        create(:membership, user: plain, organisation: organisation, role: role, active: true)
      end
      sign_in plain

      expect do
        post organisation_assistant_chats_path(organisation), params: params
      end.not_to(change { org_thread_count })
      expect(flash[:alert]).to be_present
    end

    it 'refuses while the org AI opt-in is off (no stored post, no job)' do
      organisation.update!(ai_enabled: false)
      sign_in owner

      expect do
        post organisation_assistant_chats_path(organisation), params: params
      end.not_to(change { org_thread_count })
      expect(ChatResponseJob).not_to have_been_enqueued
    end
  end

  # T4 took the SURFACE away from this route: the assistant is a companion lane,
  # not a page (L11), so show hands its thread to the panel. The DOORS below are
  # unchanged and still the point of this block -- they run before the redirect,
  # which is why every negative case still asserts the same answer as before.
  # Where the transcript and the composer are actually rendered is now pinned in
  # assistant_panel_spec.
  describe 'GET /assistant_chats/:id (show)' do
    it 'hands the thread to the companion panel instead of rendering a page' do
      sign_in owner

      get organisation_assistant_chat_path(organisation, owners_thread)

      expect(response).to redirect_to(
        organisation_root_path(organisation_id: organisation.id, assistant_chat_id: owners_thread.id)
      )
      expect(response.body).not_to include('Wie viele Stunden sind offen?')
    end

    # Uniform 404 instead of a 302+alert (T2 second review): a foreign thread of
    # the own org must be indistinguishable from a made-up id, otherwise the
    # response difference is an existence oracle on a "persoenlich ist
    # persoenlich" surface.
    it 'denies a colleague with the same assistant access (ownership decides)' do
      sign_in stranger

      get organisation_assistant_chat_path(organisation, owners_thread)

      expect(response).to have_http_status(:not_found)
    end

    # Two separate examples on purpose: after an exception-driven 404 the
    # integration session loses its login, so both halves of the oracle
    # comparison need their own request cycle.
    it 'answers a made-up id with the same 404 (no existence oracle)' do
      sign_in stranger

      get organisation_assistant_chat_path(organisation, '00000000-0000-0000-0000-000000000000')

      expect(response).to have_http_status(:not_found)
    end

    it 'denies an account_admin who is not the owner (no bypass, §13-1)' do
      sign_in admin_user

      get organisation_assistant_chat_path(organisation, owners_thread)

      expect(response).to have_http_status(:not_found)
    end

    # Was: "does not resolve a project thread over the assistant route (R-M7: own
    # doors)". projekt_chat_abbau removed the other kind of thread, so the door guard
    # has no foreign kind left to refuse. What it still refuses -- and what the R-M7
    # rule was actually about -- is a thread that is not YOURS, pinned right above.
    # The lookup that carries it (`Chat.org_threads.where(user_id:)`) keeps its
    # org_threads scope until step 5 drops the column under it.
    it 'refuses a legacy row that still carries a project (the scope holds until step 5)' do
      legacy = ActsAsTenant.with_tenant(organisation) do
        project = create(:project, organisation: organisation)
        chat = create(:chat, organisation: organisation, user: owner)
        chat.update_column(:project_id, project.id)
        chat
      end
      sign_in owner

      get organisation_assistant_chat_path(organisation, legacy)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE /assistant_chats/:id (destroy)' do
    it 'lets the owner delete their thread' do
      sign_in owner

      expect do
        delete organisation_assistant_chat_path(organisation, owners_thread)
      end.to change { org_thread_count }.by(-1)
    end

    it 'refuses a colleague' do
      sign_in stranger

      expect do
        delete organisation_assistant_chat_path(organisation, owners_thread)
      end.not_to(change { org_thread_count })
    end
  end

  describe 'chatposts in an org thread' do
    it 'lets the owner post a message and enqueues the answer' do
      sign_in owner

      expect do
        post organisation_assistant_chat_chatposts_path(organisation, owners_thread),
             params: { chatpost: { content: 'Nachfrage' } }, as: :turbo_stream
      end.to change { ActsAsTenant.with_tenant(organisation) { owners_thread.chatposts.count } }.by(1)
      expect(ChatResponseJob).to have_been_enqueued
    end

    it 'refuses a colleague posting into a foreign thread (same 404 as the show door)' do
      sign_in stranger

      expect do
        post organisation_assistant_chat_chatposts_path(organisation, owners_thread),
             params: { chatpost: { content: 'Einbruch' } }, as: :turbo_stream
      end.not_to(change { ActsAsTenant.with_tenant(organisation) { Chatpost.count } })
      expect(response).to have_http_status(:not_found)
    end

    # R-M7 door guard (T2 second review, mutation probe e): the chatposts finder
    # must stay org_threads-scoped -- widening it to Chat.find would let project
    # threads in through a door that has none of their gates (no area check).
    # The ticket-thread twin of this example went with the ticket chat (S4-T1).
    it 'does not resolve a legacy row that still carries a project' do
      legacy = ActsAsTenant.with_tenant(organisation) do
        project = create(:project, organisation: organisation)
        chat = create(:chat, organisation: organisation, user: owner)
        chat.update_column(:project_id, project.id)
        chat
      end
      sign_in owner

      post organisation_assistant_chat_chatposts_path(organisation, legacy),
           params: { chatpost: { content: 'Umweg' } }, as: :turbo_stream

      expect(response).to have_http_status(:not_found)
    end

    # Write-path twin of the component's show_delete? rule (T2 second review):
    # without it the first and only post is deletable and leaves a thread that
    # violates its own chatposts-presence validation.
    it 'refuses deleting the first post of a thread' do
      sign_in owner

      expect do
        delete organisation_assistant_chat_chatpost_path(organisation, owners_thread,
                                                         owners_thread.chatposts.first)
      end.not_to(change { ActsAsTenant.with_tenant(organisation) { owners_thread.chatposts.count } })
      expect(flash[:alert]).to eq(I18n.t('flash.chatposts.first_post_undeletable'))
    end

    it 'lets the owner delete an own deletable message' do
      extra = ActsAsTenant.with_tenant(organisation) do
        owners_thread.chatposts.create!(organisation: organisation, user: owner,
                                        role: 'user', content: 'Loeschbar')
      end
      sign_in owner

      expect do
        delete organisation_assistant_chat_chatpost_path(organisation, owners_thread, extra)
      end.to change { ActsAsTenant.with_tenant(organisation) { owners_thread.chatposts.count } }.by(-1)
    end

    it 'answers 404 for a regenerate on a missing chatpost' do
      sign_in owner

      post regenerate_organisation_assistant_chat_chatpost_path(organisation, owners_thread,
                                                                '00000000-0000-0000-0000-000000000000')

      expect(response).to have_http_status(:not_found)
    end
  end
end
