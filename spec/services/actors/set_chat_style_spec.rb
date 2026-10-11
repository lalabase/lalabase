# frozen_string_literal: true

require 'rails_helper'

# Actors::SetChatStyle — sets ONE dimension of the requesting user's persistent
# chat answer-style level to an absolute value (the pills under the composer).
#
# Intent per test: pin that setting a style is PURE STATE — it persists the level
# and enqueues nothing, because a control below the message field configures what
# comes next rather than re-running the previous answer. Plus each guard branch
# as its own failure code (:invalid_dimension / :invalid_level), so a mutation
# widening the whitelist is individually killable.
RSpec.describe Actors::SetChatStyle, type: :service do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = original
  end

  before do
    ActsAsTenant.current_tenant = organisation
    # jobs_helper stubs ChatResponseJob.perform_later suite-wide (Redis guard).
    # Here the ABSENCE of an enqueue is the subject — restore the real method so
    # a regression that starts enqueuing is actually observable.
    allow(ChatResponseJob).to receive(:perform_later).and_call_original
  end

  def call(dimension: 'technicality', level: 3)
    described_class.call(dimension: dimension, level: level, current_user: user, organisation: organisation)
  end

  describe 'happy path' do
    it 'persists the level and returns the row' do
      result = call(dimension: 'technicality', level: 3)

      expect(result).to be_success
      expect(result.resource.technicality).to eq(3)
      expect(ChatStylePreference.find_by(user: user, organisation: organisation).technicality).to eq(3)
    end

    it 'creates the row on the first click and reuses it afterwards' do
      expect { call(dimension: 'technicality', level: 1) }.to change(ChatStylePreference, :count).by(1)
      expect { call(dimension: 'length', level: 3) }.not_to change(ChatStylePreference, :count)

      row = ChatStylePreference.find_by(user: user, organisation: organisation)
      expect(row.technicality).to eq(1)
      expect(row.length).to eq(3)
    end

    it 'accepts a string level (params arrive as strings)' do
      expect(call(level: '1').resource.technicality).to eq(1)
    end

    # THE separation this whole change rests on: a style click must not cost AI
    # quota or surprise the user with a re-run answer. Re-running is the explicit
    # regenerate action (Actors::RegenerateChatpost).
    it 'enqueues NO job — setting a style triggers no answer' do
      expect { call }.not_to have_enqueued_job(ChatResponseJob)
    end
  end

  describe 'failure codes (one per guard branch)' do
    it 'maps an unknown dimension to :invalid_dimension' do
      expect(call(dimension: 'bogus').code).to eq(:invalid_dimension)
    end

    it 'maps a real-but-not-settable column to :invalid_dimension' do
      # A crafted param naming an actual column must not reach the setter.
      expect(call(dimension: 'organisation_id').code).to eq(:invalid_dimension)
    end

    it 'maps a blank dimension to :invalid_dimension' do
      expect(call(dimension: nil).code).to eq(:invalid_dimension)
    end

    # Boundaries n-1 / n / n+1 on both rails: a mutation widening LEVELS would
    # store a level the prompt lookup has no I18n key for.
    it('maps level 0 to :invalid_level') { expect(call(level: 0).code).to eq(:invalid_level) }
    it('maps level 4 to :invalid_level') { expect(call(level: 4).code).to eq(:invalid_level) }
    it('maps a nil level to :invalid_level') { expect(call(level: nil).code).to eq(:invalid_level) }
    it('maps a non-numeric level to :invalid_level') { expect(call(level: 'x').code).to eq(:invalid_level) }

    it('accepts level 1') { expect(call(level: 1)).to be_success }
    it('accepts level 3') { expect(call(level: 3)).to be_success }

    it 'writes NO row on any rejected pre-check' do
      [
        -> { call(dimension: 'bogus') },
        -> { call(level: 0) },
        -> { call(level: 4) }
      ].each(&:call)

      expect(ChatStylePreference.count).to eq(0)
    end
  end

  describe 'tenant isolation' do
    it 'writes the level only in the given organisation' do
      other_organisation = create(:organisation)
      call(dimension: 'technicality', level: 1)

      ActsAsTenant.with_tenant(other_organisation) do
        described_class.call(dimension: 'technicality', level: 3, current_user: user,
                             organisation: other_organisation)
        expect(ChatStylePreference.find_by(user: user, organisation: other_organisation).technicality).to eq(3)
      end

      expect(ChatStylePreference.find_by(user: user, organisation: organisation).technicality).to eq(1)
    end
  end
end
