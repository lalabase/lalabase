# frozen_string_literal: true

require 'rails_helper'

# Actors::CreateChatpost — appends a user message to an EXISTING chat and
# enqueues the AI answer.
#
# Intent per test: pin the server-side attribute assembly (user, organisation),
# that the role rule stays in the MODEL (Chatpost#set_initial_role — the actor
# must not duplicate it), the acting_user_id threading, the clean failure
# (invalid content → nothing persisted, no job) and the origin-agnostic cut
# (the actor serves project and org-wide threads unchanged).
RSpec.describe Actors::CreateChatpost, type: :service do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = original
  end

  before do
    ActsAsTenant.current_tenant = organisation
    # jobs_helper stubs ChatResponseJob.perform_later suite-wide (Redis guard).
    # Here the enqueue IS the subject — restore the real method; the :test
    # adapter (around hook) captures it without touching Redis.
    allow(ChatResponseJob).to receive(:perform_later).and_call_original
  end

  # let! AFTER the tenant-setting before hook (hooks run in declaration order —
  # the factory needs the tenant), and OUTSIDE the examples' expect blocks so the
  # factory's seed post can't distort the Chatpost.count change assertions.
  let!(:chat) { create(:chat, organisation: organisation) }

  def params(content)
    ActionController::Parameters.new(chatpost: { content: content })
                                .require(:chatpost).permit(:content)
  end

  describe 'happy path' do
    it 'persists the post with server-side user and organisation' do
      result = nil
      expect do
        result = described_class.call(chat: chat, params: params('A follow-up'), current_user: user)
      end.to change(Chatpost, :count).by(1)

      expect(result).to be_success
      expect(result.resource.user_id).to eq(user.id)
      expect(result.resource.organisation_id).to eq(chat.organisation_id)
      expect(result.resource.content).to eq('A follow-up')
    end

    it 'leaves the role rule to the model — a follow-up in a non-empty chat is a user post' do
      result = described_class.call(chat: chat, params: params('A follow-up'), current_user: user)

      expect(result.resource.role).to eq('user')
    end

    it 'lets the model make the FIRST post of an empty chat a system post (rule not duplicated here)' do
      # An empty chat only exists transiently (validates :chatposts, presence),
      # so build one without the factory's seed post and bypass validation the
      # way no surface does any more: create chat + first post together.
      empty_chat = ActsAsTenant.with_tenant(organisation) do
        Chat.new(organisation: organisation, user: user).tap do |c|
          c.save!(validate: false)
        end
      end

      result = described_class.call(chat: empty_chat, params: params('very first message'), current_user: user)

      expect(result).to be_success
      expect(result.resource.role).to eq('system') # Chatpost#set_initial_role decided, not the actor
    end

    it 'enqueues the answer WITH acting_user_id (the job resolves the per-user style level)' do
      expect { described_class.call(chat: chat, params: params('A follow-up'), current_user: user) }
        .to have_enqueued_job(ChatResponseJob).with(chat, acting_user_id: user.id, question_chatpost_id: kind_of(String))
    end
  end

  describe 'validation failure (blank content)' do
    it 'persists nothing and returns the invalid post for the composer re-render' do
      result = nil
      expect do
        result = described_class.call(chat: chat, params: params(''), current_user: user)
      end.not_to change(Chatpost, :count)

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      expect(result.resource).to be_a(Chatpost)
      expect(result.resource.errors[:content]).to be_present
    end

    it 'enqueues no job' do
      expect { described_class.call(chat: chat, params: params(''), current_user: user) }
        .not_to have_enqueued_job(ChatResponseJob)
    end
  end
end
