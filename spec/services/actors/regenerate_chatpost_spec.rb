# frozen_string_literal: true

require 'rails_helper'

# Actors::RegenerateChatpost — re-enqueues the answer for one assistant post.
#
# Intent per test: pin each pre-check as its OWN failure code (E2 — :not_found /
# :not_regenerable, so every guard branch is individually killable), that a
# rejected pre-check enqueues NO job (pre-checks precede every effect), and the
# happy path: the job carries regenerate_chatpost_id + acting_user_id.
#
# 2026-07-19: the actor no longer takes a `style` and no longer writes a style
# nudge — the style lives in ChatStylePreference, set explicitly through the
# pills under the composer (Actors::SetChatStyle). The "touches no preference"
# example below pins that separation.
RSpec.describe Actors::RegenerateChatpost, type: :service do
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

  let!(:chat) { create(:chat, organisation: organisation) }
  let!(:answer) do
    create(:chatpost, chat: chat, role: 'assistant', user: nil, content: 'an answer', model_used: 'gpt-x')
  end

  def call(chatpost_id: answer.id)
    described_class.call(chat: chat, chatpost_id: chatpost_id, current_user: user)
  end

  describe 'happy path' do
    it 'returns the target post as resource' do
      result = call
      expect(result).to be_success
      expect(result.resource).to eq(answer)
    end

    # .with is an EXACT argument match, so this also pins the absence of a style
    # kwarg: a mutation re-adding one would make the job carry a one-off
    # directive again, reintroducing the two-sources-of-style split.
    it 'enqueues the regenerate job with exactly regenerate_chatpost_id and acting_user_id' do
      expect { call }
        .to have_enqueued_job(ChatResponseJob)
        .with(chat, regenerate_chatpost_id: answer.id, acting_user_id: user.id)
    end

    it 'touches NO style preference (regenerating is a pure action)' do
      # The old pills nudged the stored level as a side effect of regenerating.
      # Setting a style is now exclusively Actors::SetChatStyle's job — if this
      # actor ever writes again, the user's level would drift behind their back.
      expect { call }.not_to change(ChatStylePreference, :count)
      expect(ChatStylePreference.find_by(user: user, organisation: organisation)).to be_nil
    end
  end

  describe 'failure codes (E2 — one per guard branch)' do
    it 'maps an unknown chatpost id to :not_found' do
      result = call(chatpost_id: SecureRandom.uuid)

      expect(result).not_to be_success
      expect(result.code).to eq(:not_found)
    end

    it 'maps a chatpost of ANOTHER chat to :not_found (scoped lookup)' do
      other_chat = create(:chat, organisation: organisation)
      foreign = create(:chatpost, chat: other_chat, role: 'assistant', user: nil,
                                  content: 'foreign', model_used: 'm')

      expect(call(chatpost_id: foreign.id).code).to eq(:not_found)
    end

    it 'maps a non-assistant post to :not_regenerable' do
      user_post = create(:chatpost, chat: chat, role: 'user', user: user, content: 'a question')

      expect(call(chatpost_id: user_post.id).code).to eq(:not_regenerable)
    end

    it 'enqueues NO job on any rejected pre-check' do
      [
        -> { call(chatpost_id: SecureRandom.uuid) },
        -> { call(chatpost_id: create(:chatpost, chat: chat, role: 'user', user: user, content: 'q').id) }
      ].each do |rejected_call|
        expect { rejected_call.call }.not_to have_enqueued_job(ChatResponseJob)
      end
    end
  end
end
