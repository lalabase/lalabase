# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Mcp::IdempotencyStore do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:token) { create(:personal_access_token, user: user, organisations: [organisation]) }

  def store(key:, args:, the_token: token)
    described_class.new(token: the_token, tool_name: 'create_ticket', key: key, args: args)
  end

  describe '#replay' do
    it 'returns nil when the key has not been seen (caller should execute)' do
      expect(store(key: 'k', args: { a: 1 }).replay).to be_nil
    end

    it 'replays the stored content for the same key + same args' do
      store(key: 'k', args: { a: 1 }).remember('{"id":"123"}')

      result = store(key: 'k', args: { a: 1 }).replay
      expect(result.success?).to be true
      expect(result.content).to eq('{"id":"123"}')
    end

    it 'refuses to replay when the same key is reused with different args' do
      store(key: 'k', args: { a: 1 }).remember('{"id":"123"}')

      result = store(key: 'k', args: { a: 2 }).replay
      expect(result.success?).to be false
      expect(result.error).to match(/different parameters/i)
    end

    it 'is order-insensitive at the top level (same args, different key order)' do
      store(key: 'k', args: { a: 1, b: 2 }).remember('{"id":"123"}')

      expect(store(key: 'k', args: { b: 2, a: 1 }).replay.success?).to be true
    end
  end

  describe '#remember' do
    it 'keeps a single row per (token, key) and swallows the race (requires_new savepoint)' do
      store(key: 'k', args: { a: 1 }).remember('first')

      expect { store(key: 'k', args: { a: 1 }).remember('second') }
        .not_to change(McpIdempotencyKey, :count)
    end

    it 'isolates keys per token' do
      store(key: 'shared', args: { a: 1 }).remember('a')

      other = create(:personal_access_token, user: user, organisations: [organisation])
      expect(store(key: 'shared', args: { a: 1 }, the_token: other).replay).to be_nil
    end
  end
end
