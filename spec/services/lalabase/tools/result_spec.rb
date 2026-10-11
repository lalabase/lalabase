# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Tools::Result do
  describe '#success?' do
    it 'is true when error is nil' do
      expect(described_class.new(content: 'ok').success?).to be true
    end

    it 'is false when error is set' do
      expect(described_class.new(error: 'bad').success?).to be false
    end

    it 'is true even when content is nil — success means error.blank?, not content.present?' do
      expect(described_class.new.success?).to be true
    end

    # R4-1: empty-string error must NOT be treated as a failure. Defends
    # against `Result.new(error: msg || '')` accidentally poisoning the
    # audit trail with "ERROR: " rows.
    it 'treats an empty-string error as success (no audit poisoning)' do
      r = described_class.new(content: 'ok', error: '')
      expect(r.success?).to be true
      expect(r.kind).to eq(:ok)
      expect(r.summary_for_audit).to eq('ok')
    end

    it 'treats a whitespace-only error as success (blank? semantics)' do
      expect(described_class.new(error: '   ').success?).to be true
    end
  end

  describe '#kind' do
    it 'defaults to :ok when no error is set' do
      expect(described_class.new(content: 'x').kind).to eq(:ok)
    end

    it 'defaults to :error when error is set' do
      expect(described_class.new(error: 'bad').kind).to eq(:error)
    end

    it 'honors an explicit :empty kind (e.g. for not-found success results)' do
      r = described_class.new(content: 'nothing here', citations: [], kind: :empty)
      expect(r.kind).to eq(:empty)
      expect(r.empty?).to be true
      expect(r.success?).to be true # not-found is still a successful tool execution
    end

    # R3-1: error result is ALWAYS :error, regardless of any explicit kind.
    # Without this invariant a tool that accidentally sets kind would silently
    # hide the failure from chatposts.tool_calls.
    it 'returns :error when error is present, regardless of explicit kind: :ok' do
      r = described_class.new(content: 'x', error: 'fail', kind: :ok)
      expect(r.success?).to be false
      expect(r.kind).to eq(:error)
    end

    it 'returns :error when error is present, regardless of explicit kind: :empty' do
      r = described_class.new(content: 'x', error: 'fail', kind: :empty)
      expect(r.success?).to be false
      expect(r.kind).to eq(:error)
      expect(r.summary_for_audit).to eq('ERROR: fail')
    end

    # R3-6: typo guard. Unknown kind values fall back to :ok with a warning
    # so the drift surfaces in production logs.
    it 'warns and defaults to :ok for unknown kind values (typo guard)' do
      allow(Rails.logger).to receive(:warn)
      r = described_class.new(content: 'x', kind: :emty) # deliberate typo
      expect(r.kind).to eq(:ok)
      expect(Rails.logger).to have_received(:warn).with(/unknown kind :emty/)
    end

    it 'silently accepts every value in VALID_KINDS (no warn log)' do
      expect(Rails.logger).not_to receive(:warn)
      described_class::VALID_KINDS.each do |kind|
        # error present → invariant forces :error regardless; test the explicit
        # path by leaving error nil so explicit kind wins.
        described_class.new(content: 'x', kind: kind).kind
      end
    end

    it 'VALID_KINDS is the contract (mutation guard)' do
      # Positive iteration — adding a new kind requires deliberately extending
      # this list, removing one breaks the test immediately.
      expect(described_class::VALID_KINDS).to contain_exactly(:ok, :empty, :error)
    end
  end

  describe '#summary_for_audit' do
    it 'prefixes errors with ERROR: even if content is also set' do
      result = described_class.new(content: 'partial', error: 'embedding failed')
      expect(result.summary_for_audit).to eq('ERROR: embedding failed')
    end

    it 'prefixes empty results with NO MATCH:' do
      r = described_class.new(content: 'No capability found for abc.', citations: [], kind: :empty)
      expect(r.summary_for_audit).to eq('NO MATCH: No capability found for abc.')
    end

    it 'truncates empty-result content to 60 chars' do
      long = 'no match found ' * 20
      r = described_class.new(content: long, citations: [], kind: :empty)
      expect(r.summary_for_audit).to start_with('NO MATCH: ')
      expect(r.summary_for_audit.length).to be <= 60 + 'NO MATCH: '.length
    end

    it 'truncates string content to exactly 100 chars (boundary)' do
      long = 'a' * 200
      expect(described_class.new(content: long).summary_for_audit).to eq('a' * 100)
    end

    it 'returns string content unchanged when within 100 chars' do
      expect(described_class.new(content: 'short result').summary_for_audit).to eq('short result')
    end

    it 'returns string content unchanged at exactly 100 chars (boundary n)' do
      exactly = 'a' * 100
      expect(described_class.new(content: exactly).summary_for_audit).to eq(exactly)
    end

    it 'falls back to citation-count summary for non-string content' do
      result = described_class.new(content: { foo: :bar }, citations: [1, 2, 3])
      expect(result.summary_for_audit).to eq('data (3 citations)')
    end

    it 'reports zero citations when both content and citations are nil' do
      expect(described_class.new.summary_for_audit).to eq('data (0 citations)')
    end
  end

  describe '#coverage (L7 contract field, S3a T3)' do
    it 'defaults to nil (coverage not applicable, e.g. single-project call)' do
      expect(described_class.new(content: 'x').coverage).to be_nil
    end

    it 'carries the searched/total numbers a tool reports' do
      r = described_class.new(content: 'x', coverage: { searched: 3, total: 12 })
      expect(r.coverage).to eq(searched: 3, total: 12)
    end
  end

  # The machine field of an error (terminal client plan, S0 c): Mcp::ToolCall puts
  # it on the wire, so a client stops parsing the prose.
  describe '#error_code' do
    it 'is nil for a success, whatever code was passed' do
      expect(described_class.new(content: 'x', code: :invalid_input).error_code).to be_nil
      expect(described_class.new(content: 'x', kind: :empty).error_code).to be_nil
    end

    it 'is the explicit code of an error' do
      described_class::ERROR_CODES.each do |code|
        expect(described_class.new(error: 'bad', code: code).error_code).to eq(code)
      end
    end

    # The plan's rule for the unknown: a refusal, never something a client retries.
    it 'defaults to :refused for an error without a code' do
      expect(described_class.new(error: 'bad').error_code).to eq(:refused)
    end

    it 'warns and falls back to :refused for an unknown code (typo guard)' do
      allow(Rails.logger).to receive(:warn)
      expect(described_class.new(error: 'bad', code: :invalid_inptu).error_code).to eq(:refused)
      expect(Rails.logger).to have_received(:warn).with(/unknown code :invalid_inptu/)
    end

    it 'ERROR_CODES is the contract (mutation guard)' do
      expect(described_class::ERROR_CODES)
        .to contain_exactly(:invalid_input, :read_only, :not_found, :forbidden, :refused)
    end
  end

  describe '.invalid_input' do
    it 'is an error with the code :invalid_input and no reason' do
      result = described_class.invalid_input('title is required')
      expect([result.success?, result.error, result.error_code, result.reason])
        .to eq([false, 'title is required', :invalid_input, nil])
    end
  end

  describe '.refused' do
    it 'is an error with the code :refused and the given reason' do
      result = described_class.refused('notification is archived', reason: :archived)
      expect([result.success?, result.error, result.error_code, result.reason])
        .to eq([false, 'notification is archived', :refused, :archived])
    end
  end
end
