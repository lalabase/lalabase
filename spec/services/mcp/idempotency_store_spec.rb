# frozen_string_literal: true

require 'rails_helper'

# What: the idempotency store of the MCP and /api/v1 writes, and the one rule
#   of which key it can hold (.client_key, .storable_key?), asked by both
#   surfaces before a write runs.
# Why: the key is stored only after the write. A key the store cannot hold
#   (too long for the unique index, no valid UTF-8, a NUL) used to write and
#   then fail; a key read differently on the two surfaces would be refused on
#   one and kept on the other.
#
# Security spec: tagged :ci_guard and listed in .github/workflows/guards.yml.
RSpec.describe Mcp::IdempotencyStore, :ci_guard do
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

    # What .storable_key? accepts the table takes: the bound sits far inside the index.
    it 'remembers and replays a key of the limit, umlauts included' do
      key = "#{'ä' * 127}k"
      store(key: key, args: { a: 1 }).remember('{"id":"123"}')

      expect(store(key: key, args: { a: 1 }).replay.content).to eq('{"id":"123"}')
    end
  end

  describe '.client_key' do
    it 'drops surrounding whitespace' do
      expect(described_class.client_key("  k-1\t\n")).to eq('k-1')
    end

    it 'reads a blank key, or none, as no key' do
      expect(['', '   ', nil].map { |raw| described_class.client_key(raw) }).to all(be_nil)
    end

    # String#strip treats a NUL at either end like whitespace; only one inside
    # the key reaches .storable_key?.
    it 'drops a NUL at either end, as String#strip does' do
      expect(described_class.client_key("\0k\0")).to eq('k')
    end

    # String#strip raises on such bytes. They come back as sent, for
    # .storable_key? to refuse.
    it 'returns bytes that are no valid UTF-8 as sent, without raising' do
      raw = " k\xFF ".dup.force_encoding(Encoding::UTF_8)

      expect(described_class.client_key(raw)).to eq(raw)
    end

    # A REST header arrives as binary, a valid encoding: stripped as before.
    it 'strips a binary header like any other key' do
      expect(described_class.client_key(' k-1 '.b)).to eq('k-1'.b)
    end

    # Blank is Rails' blank? in the key's own encoding, as before on both
    # surfaces: in UTF-8 (an MCP argument) a Unicode space is blank, so the call
    # has no key; in binary (a REST header from Puma) only an ASCII space is, so
    # the same bytes are a key there, and the model, which sees the same binary
    # string, stores it.
    it 'reads Unicode spaces alone as no key in UTF-8 and as a key in binary' do
      expect(described_class.client_key("\u00A0")).to be_nil
      expect(described_class.client_key("\xC2\xA0".b)).to eq("\xC2\xA0".b)
    end
  end

  describe '.storable_key?' do
    let(:limit) { described_class::MAX_KEY_LENGTH }

    it 'holds a key of exactly the limit in bytes, umlauts included' do
      expect(described_class.storable_key?('k' * limit)).to be(true)
      expect(described_class.storable_key?("#{'ä' * 127}k")).to be(true)
    end

    it 'refuses one byte more, counting bytes and not characters' do
      expect(described_class.storable_key?('k' * (limit + 1))).to be(false)
      expect(described_class.storable_key?('ä' * 128)).to be(false)
    end

    it 'refuses a NUL inside the key' do
      expect(described_class.storable_key?("k\0x")).to be(false)
    end

    it 'refuses bytes that are no valid UTF-8, sent as binary or as UTF-8' do
      expect(described_class.storable_key?("k\xFFx".b)).to be(false)
      expect(described_class.storable_key?("k\xFFx".dup.force_encoding(Encoding::UTF_8))).to be(false)
    end

    it 'holds a binary key whose bytes are valid UTF-8' do
      expect(described_class.storable_key?('schlüssel'.b)).to be(true)
    end

    # The model refuses a blank key (presence), after the write: blank in the
    # key's own encoding, as the model sees it.
    it 'refuses a blank key, holding Unicode spaces only in binary' do
      expect(['', " \t", "\u00A0"].map { |key| described_class.storable_key?(key) }).to all(be(false))
      expect(described_class.storable_key?("\xC2\xA0".b)).to be(true)
    end
  end

  describe '.new' do
    # Both surfaces refuse such a key before the write. One that forgot would
    # otherwise fail only in #remember, after the write, and its retry would
    # write again: the store refuses it before anything runs.
    it 'refuses a key the store cannot hold' do
      ['k' * 256, "k\0x", "k\xFFx".b, ''].each do |key|
        expect { store(key: key, args: { a: 1 }) }.to raise_error(ArgumentError, /cannot hold/)
      end
    end
  end

  it 'names the field and the bound in its refusal' do
    expect(described_class.unstorable_key_message('idempotency_key'))
      .to eq('idempotency_key must be valid UTF-8 without NUL, at most 255 bytes')
  end
end
