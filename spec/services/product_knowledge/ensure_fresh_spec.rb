# frozen_string_literal: true

require 'rails_helper'

# What:  ProductKnowledge::EnsureFresh, which syncs the table only when it no longer equals the
#        files, and never runs the expensive part on every read.
# Type:  Service test with the sources stubbed to two synthetic rows (de, en).
# Why:   It carries D4 of the plan, and the review found each of these failing quietly before:
#        syncing on every read (about 100 ms each), trusting a stored value instead of the
#        table, a check under the lock answered by the query cache, an older release restoring
#        its older texts during a deploy, a missing language deleting its rows, a blocking lock,
#        and an error that takes every read down with it. Each example below pins one of them.
RSpec.describe ProductKnowledge::EnsureFresh do
  include ActiveSupport::Testing::TimeHelpers

  before do
    @rows = [product_knowledge_row('a', 'Erster Text'), product_knowledge_row('a', 'First text', locale: 'en')]
    @stamp = [[1, 1_000], [1, 1_000]]
    allow(ProductKnowledge::Sources).to receive(:rows) { @rows }
    allow(ProductKnowledge::Sources).to receive(:stamp) { @stamp }
  end

  def stored_generation
    SystemSetting.get(described_class::GENERATION_KEY)
  end

  def sql_during(&)
    statements = []
    callback = ->(*, payload) { statements << payload[:sql].to_s }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    statements
  end

  # Answers the lock query itself, and runs `before_answer` first: what another process does
  # while this one asks for the lock.
  def stub_lock(answer: nil, &before_answer)
    connection = ProductKnowledgeEntry.connection
    allow(connection).to receive(:select_value).and_wrap_original do |original, sql, *args, **kwargs|
      if sql.to_s.include?('pg_try_advisory_xact_lock')
        before_answer&.call
        answer.nil? ? original.call(sql, *args, **kwargs) : answer
      else
        original.call(sql, *args, **kwargs)
      end
    end
  end

  it 'fills an empty table and stores the generation of the files it wrote' do
    result = described_class.call

    expect(result.to_h).to eq(written: 2, deleted: 0)
    expect(ProductKnowledgeEntry.order(:locale).pluck(:locale, :slug)).to eq([%w[de a], %w[en a]])
    expect(stored_generation).to eq(1_000)
  end

  describe 'the memo' do
    it 'builds no rows and touches no database when this process already verified the stamp' do
      described_class.call

      expect(sql_during { expect(described_class.call).to be_nil }).to be_empty
      expect(ProductKnowledge::Sources).to have_received(:rows).once
    end

    it 'looks again once MEMO_TTL has passed' do
      described_class.call
      travel(described_class::MEMO_TTL + 1.second) { described_class.call }

      expect(ProductKnowledge::Sources).to have_received(:rows).twice
    end

    it 'looks again as soon as the files change' do
      described_class.call
      @stamp = [[1, 2_000], [1, 2_000]]
      @rows[0] = product_knowledge_row('a', 'Neuer Text')

      expect(described_class.call.to_h).to eq(written: 1, deleted: 0)
      expect(ProductKnowledgeEntry.find_by!(locale: 'de').body_markdown).to eq('Neuer Text')
      expect(stored_generation).to eq(2_000)
    end
  end

  describe 'the table as the truth' do
    it 'refills a table that was emptied behind its back' do
      described_class.call
      ProductKnowledgeEntry.delete_all
      described_class.forget!

      expect(described_class.call.to_h).to eq(written: 2, deleted: 0)
    end

    it 'does not sync while the table already equals the files' do
      described_class.call
      described_class.forget!
      allow(ProductKnowledge::Sync).to receive(:call).and_call_original

      expect(described_class.call).to be_nil
      expect(ProductKnowledge::Sync).not_to have_received(:call)
    end

    it 'syncs files of the same generation that differ from the table' do
      described_class.call
      ProductKnowledgeEntry.update_all(content_hash: 'changed elsewhere')
      described_class.forget!

      expect(described_class.call.to_h).to eq(written: 2, deleted: 0)
    end
  end

  describe 'an older catalogue' do
    # This used to be refused. The rule was written for app/docs INSIDE a
    # release, where a process of the previous one could write its older texts
    # back; the catalogue is one file in shared/, so that cannot happen. What
    # the rule did catch was a restore or a rollback, silently, and the
    # assistant then kept rows the help no longer showed.
    it 'is synced, because the catalogue is the truth in both directions' do
      described_class.call
      SystemSetting.set(described_class::GENERATION_KEY, 5_000)
      ProductKnowledgeEntry.update_all(body_markdown: 'newer', content_hash: 'newer')
      described_class.forget!

      expect(described_class.call.to_h).to eq(written: 2, deleted: 0)
      expect(ProductKnowledgeEntry.distinct.pluck(:body_markdown)).not_to eq(['newer'])
    end

    it 'says in the log that it went backwards, so a restore is findable' do
      described_class.call
      SystemSetting.set(described_class::GENERATION_KEY, 5_000)
      ProductKnowledgeEntry.update_all(content_hash: 'newer')
      described_class.forget!

      expect(Rails.logger).to receive(:info).with(/OLDER catalogue/)
      described_class.call
    end

    it 'does not sync when the table already matches, whatever the generation says' do
      described_class.call
      SystemSetting.set(described_class::GENERATION_KEY, 5_000)
      described_class.forget!
      allow(ProductKnowledge::Sync).to receive(:call).and_call_original

      expect(described_class.call).to be_nil
      expect(ProductKnowledge::Sync).not_to have_received(:call)
    end

    it 'rewrites every row on force' do
      described_class.call
      SystemSetting.set(described_class::GENERATION_KEY, 5_000)

      expect(described_class.call(force: true).to_h).to eq(written: 2, deleted: 0)
      expect(stored_generation).to eq(1_000)
    end
  end

  describe 'an incomplete source' do
    it 'refuses to sync when a language yields no pages, and keeps its rows' do
      described_class.call
      @rows = @rows.first(1)
      # nil, not [0, 0]: a language without a catalogue file has no stamp at
      # all, and a zero would drag the generation down.
      @stamp = [[1, 2_000], nil]
      allow(Rails.logger).to receive(:error)

      expect(described_class.call).to be_nil
      expect(Rails.logger).to have_received(:error).with(/no help pages for en/)
      expect(ProductKnowledgeEntry.pluck(:locale)).to contain_exactly('de', 'en')
    end

    # The distinction matters because of WHO reads the log. A broken pair is a
    # half-written deploy and somebody has to look; no catalogue at all is the
    # normal state of a self-hosted instance and of every development machine,
    # and it lasts forever. Logged as an error, it filled that operator's log
    # every five minutes per process and buried what mattered. Found in review
    # of the D5 PR, where the new documentation claimed the opposite.
    it 'says nothing alarming when there is no catalogue AT ALL' do
      described_class.call
      @rows = []
      @stamp = [nil, nil]
      allow(Rails.logger).to receive(:error)
      allow(Rails.logger).to receive(:info)

      expect(described_class.call).to be_nil
      expect(Rails.logger).to have_received(:info).with(/no catalogue to read/)
      expect(Rails.logger).not_to have_received(:error)
      expect(ProductKnowledgeEntry.pluck(:locale)).to contain_exactly('de', 'en')
    end
  end

  describe 'the lock' do
    # Its own savepoint means a failure rolls back only its own work instead of aborting a
    # caller's transaction. A spec's fixture transaction is not joinable, so only a caller's
    # transaction shows the difference: joined, the lock would follow the reads directly.
    it 'takes a lock that does not wait, in its own savepoint even inside a caller transaction' do
      statements = sql_during { ProductKnowledgeEntry.transaction { described_class.call } }

      lock_at = statements.index { |sql| sql.include?('pg_try_advisory_xact_lock') }
      write_at = statements.index { |sql| sql.match?(/INSERT INTO "product_knowledge_entries"/) }
      expect([lock_at, write_at]).to all(be_an(Integer))
      savepoint = statements[lock_at - 1][/\ASAVEPOINT (\w+)/, 1]
      expect(savepoint).to be_present, "expected a SAVEPOINT right before the lock, got: #{statements[lock_at - 1]}"
      expect(lock_at).to be < write_at
      expect(statements[write_at..]).to include("RELEASE SAVEPOINT #{savepoint}")
    end

    it 'reads the table as it is when another process holds the lock, and looks again next time' do
      stub_lock(answer: false)
      allow(ProductKnowledge::Sync).to receive(:call).and_call_original

      expect(described_class.call).to be_nil
      expect(ProductKnowledge::Sync).not_to have_received(:call)
      expect(described_class.verified?(@stamp)).to be false
    end

    it 'checks again under the lock and leaves a sync another process just finished alone' do
      rows = @rows
      stub_lock { ProductKnowledge::Sync.call(rows: rows) }
      allow(ProductKnowledge::Sync).to receive(:call).and_call_original

      expect(described_class.call).to be_nil
      expect(ProductKnowledge::Sync).to have_received(:call).once
    end

    it 'reads past the query cache, which would answer the check under the lock from before it' do
      cache_enabled = []
      allow(ProductKnowledgeEntry).to receive(:pluck).and_wrap_original do |original, *args|
        cache_enabled << ProductKnowledgeEntry.connection.query_cache_enabled
        original.call(*args)
      end

      ActiveRecord::Base.cache { described_class.call }

      expect(cache_enabled).to be_present
      expect(cache_enabled).to all(be(false))
    end
  end

  describe 'an error' do
    it 'raises in development and test, like any unexpected error' do
      allow(ProductKnowledge::Sync).to receive(:call).and_raise(ActiveRecord::StatementInvalid, 'boom')

      expect { described_class.call }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it 'is reported in production, and the rows already there stay readable' do
      described_class.call
      @stamp = [[1, 2_000], [1, 2_000]]
      @rows[0] = product_knowledge_row('a', 'Neuer Text')
      allow(Rails.env).to receive(:local?).and_return(false)
      allow(Rails.error).to receive(:report)
      allow(ProductKnowledge::Sync).to receive(:call).and_raise(ActiveRecord::StatementInvalid, 'boom')

      expect(described_class.call).to be_nil
      expect(Rails.error).to have_received(:report).with(an_instance_of(ActiveRecord::StatementInvalid), handled: true)
      expect(ProductKnowledgeEntry.find_by!(locale: 'de').body_markdown).to eq('Erster Text')
    end
  end
end
