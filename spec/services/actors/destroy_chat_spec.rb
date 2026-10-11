# frozen_string_literal: true

require 'rails_helper'

# Actors::DestroyChat — destroys a chat with ALL of its posts in one transaction.
#
# Intent per test: prove the plain `dependent: :destroy` cascade removes every
# post INCLUDING the system post (destroyed_by_association skips the guard in
# Chatpost#destroy), and that a mid-cascade failure rolls the whole delete back —
# the exact bug the old controller loop had, whose inner rescue committed the
# already-destroyed posts (partial delete).
RSpec.describe Actors::DestroyChat, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  # A chat with its system post (factory) + two user posts. Passed to the actor
  # as a FRESH instance (like the controller's set_chat find): the factory-built
  # record keeps a loaded chatposts association cache that predates the two extra
  # posts, and `dependent: :destroy` cascades over the loaded target — a stale
  # cache would silently skip posts and test nothing real.
  let!(:seeded_chat) do
    create(:chat, organisation: organisation).tap do |c|
      create(:chatpost, chat: c, user: user, role: 'user', content: 'first question')
      create(:chatpost, chat: c, user: user, role: 'user', content: 'second question')
    end
  end
  let(:chat) { Chat.find(seeded_chat.id) }

  describe '#record' do
    it 'is nil — a destroy leaves no surviving primary record' do
      expect(described_class.new(chat: chat, current_user: user).record).to be_nil
    end
  end

  describe '#call' do
    context 'happy path' do
      it 'destroys the chat' do
        expect { described_class.call(chat: chat, current_user: user) }
          .to change(Chat, :count).by(-1)
      end

      it 'destroys ALL posts including the system post (cascade skips the guard)' do
        expect { described_class.call(chat: chat, current_user: user) }
          .to change(Chatpost, :count).by(-3)
      end

      it 'returns a successful Result with resource nil' do
        result = described_class.call(chat: chat, current_user: user)

        expect(result).to be_success
        expect(result.resource).to be_nil
        expect(result.errors).to be_empty
      end
    end

    context 'rollback when a chatpost destroy fails mid-cascade' do
      before do
        # The same failure shape the request-level regression test uses: the LAST
        # post's destroy raises RecordInvalid (a callback error). F4 verified:
        # Chat/Chatpost have no destroy-side callbacks beyond the guard override,
        # and the broadcasts rescue internally — so the stub is the realistic way
        # to fail the cascade deterministically.
        failing = chat.chatposts.order(:created_at).last
        allow_any_instance_of(Chatpost).to receive(:destroy).and_wrap_original do |m, *args|
          raise ActiveRecord::RecordInvalid, m.receiver if m.receiver.id == failing.id

          m.call(*args)
        end
      end

      it 'returns a failure Result mapped to :validation_failed' do
        result = described_class.call(chat: chat, current_user: user)

        expect(result).not_to be_success
        expect(result.code).to eq(:validation_failed)
      end

      it 'rolls the WHOLE delete back — no partial commit' do
        expect { described_class.call(chat: chat, current_user: user) }
          .not_to change(Chatpost, :count)

        expect(Chat.exists?(chat.id)).to be(true)
        expect(chat.reload.chatposts.count).to eq(3)
      end
    end
  end
end
