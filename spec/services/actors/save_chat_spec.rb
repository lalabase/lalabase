# frozen_string_literal: true

require 'rails_helper'

# Actors::SaveChat — creates a chat with its first (nested) posts and enqueues
# the first AI answer.
#
# Intent per test: pin the params contract (author forced to current_user, a
# spoofed user_id never wins), the F3 parity (first answer enqueued WITHOUT
# acting_user_id — the deliberate status quo), the OWNERSHIP the assistant plan's
# S1 introduces (the thread itself belongs to the asker, set server-side like the
# post author), and the all-or-nothing failure (invalid chat → :validation_failed,
# resource carries the errors, nothing persisted, no job).
RSpec.describe Actors::SaveChat, type: :service do
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

  def params(overrides = {})
    ActionController::Parameters.new(
      chat: { chatposts_attributes: { '0' => { content: 'First question' }.merge(overrides) } }
    ).require(:chat).permit(:title, :prompt_persona_id, chatposts_attributes: %i[content])
  end

  # S1 (doc/persoenlicher_assistent_plan.md §5, §10): a thread belongs to the person
  # who started it. This is the ONE place a thread gets its owner, so it is
  # also the place where a spoofed owner has to lose — same contract as the post
  # author right below.
  describe 'ownership of the thread' do
    it 'assigns the asking user as the owner of the chat' do
      result = described_class.call(params: params, current_user: user)

      expect(result.resource.user).to eq(user)
    end

    it 'ignores a user_id smuggled into the params' do
      intruder = create(:user)
      smuggled = ActionController::Parameters.new(
        chat: { user_id: intruder.id, chatposts_attributes: { '0' => { content: 'First question' } } }
      ).require(:chat).permit(:title, :prompt_persona_id, :user_id, chatposts_attributes: %i[content])

      result = described_class.call(params: smuggled, current_user: user)

      expect(result.resource.user).to eq(user)
    end
  end

  describe 'happy path' do
    it 'persists the chat with its nested first post' do
      expect { described_class.call(params: params, current_user: user) }
        .to change(Chat, :count).by(1).and change(Chatpost, :count).by(1)
    end

    it 'returns the persisted chat as resource' do
      result = described_class.call(params: params, current_user: user)

      expect(result).to be_success
      expect(result.resource).to be_a(Chat)
      expect(result.resource).to be_persisted
      # projekt_chat_abbau dropped the actor's `project:` argument: it selected which
      # collection the thread was built through, and there is one kind left.
      expect(result.resource.project_id).to be_nil
    end

    it 'forces the post author to current_user (server-side, never from params)' do
      result = described_class.call(params: params, current_user: user)

      expect(result.resource.chatposts.map(&:user_id)).to all(eq(user.id))
    end

    it 'ignores a spoofed user_id — the permit contract only lets :content through' do
      victim = create(:user)
      # Mirrors the controller's chat_params permit: a crafted user_id is dropped
      # by strong params BEFORE the actor; the actor then assigns the author
      # itself. Both layers together are the mass-assignment contract.
      spoofed = ActionController::Parameters.new(
        chat: { chatposts_attributes: { '0' => { content: 'spoofed', user_id: victim.id } } }
      ).require(:chat).permit(:title, :prompt_persona_id, chatposts_attributes: %i[content])

      result = described_class.call(params: spoofed, current_user: user)

      expect(result.resource.chatposts.first.user_id).to eq(user.id)
    end

    it 'enqueues the first answer WITHOUT acting_user_id (F3 parity — neutral style default, pinned)' do
      result = nil
      expect do
        result = described_class.call(params: params, current_user: user)
      end.to have_enqueued_job(ChatResponseJob)

      # Pin the question identity and the unchanged neutral style. A mutation
      # that threads acting_user_id here is a (currently undecided) behaviour
      # change and must turn this red. Select by job_class — .last would break
      # for an unrelated reason once another job enqueues in the create path.
      job = enqueued_jobs.find { |j| j['job_class'] == 'ChatResponseJob' }
      expect(job['arguments'].length).to eq(2)
      expect(job['arguments'].last.except('_aj_ruby2_keywords')).to eq('question_chatpost_id' => result.resource.chatposts.first.id)
      expect(job['arguments'].first['_aj_globalid']).to eq(result.resource.to_global_id.to_s)
    end
  end

  describe 'validation failure (blank first post)' do
    let(:invalid_params) { params(content: '') }

    it 'persists nothing' do
      expect { described_class.call(params: invalid_params, current_user: user) }
        .not_to(change { [Chat.count, Chatpost.count] })
    end

    it 'returns :validation_failed with the invalid chat carrying its errors (form re-render)' do
      result = described_class.call(params: invalid_params, current_user: user)

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      expect(result.resource).to be_a(Chat)
      expect(result.resource.errors).not_to be_empty
    end

    it 'enqueues no job' do
      expect { described_class.call(params: invalid_params, current_user: user) }
        .not_to have_enqueued_job(ChatResponseJob)
    end
  end
end
