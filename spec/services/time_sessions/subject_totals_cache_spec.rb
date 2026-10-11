# frozen_string_literal: true

require 'rails_helper'

# The caching rule the ticket table depends on, on its own: a preloaded page is
# answered from memory, and a ticket the preload never saw is LOOKED UP rather
# than answered with a zero. The second half is the one that rots quietly -- a
# zeroed miss renders an empty cell, which looks like "nothing booked" instead of
# like a bug.
RSpec.describe TimeSessions::SubjectTotalsCache do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:other_ticket) { create(:ticket, project: project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation,
                        role: create(:admin_role, organisation: organisation))
  end

  after { ActsAsTenant.current_tenant = nil }

  def book(on:, minutes: 60)
    create(:time_session, project: project, organisation: organisation, creator: user,
                          ticket: on, duration: minutes, occurred_on: 2.days.ago)
  end

  describe 'a preloaded page' do
    it 'answers from the preload without going back to the database' do
      book(on: ticket, minutes: 90)
      cache = described_class.new(user: user).preload([ticket])

      expect(TimeSessions::SubjectTotals).not_to receive(:call)
      expect(cache.fetch(ticket)).to include(minutes: 90)
    end

    it 'answers a preloaded ticket that has nothing booked, still without a query' do
      cache = described_class.new(user: user).preload([ticket])

      expect(TimeSessions::SubjectTotals).not_to receive(:call)
      expect(cache.fetch(ticket)).to eq(TimeSessions::SubjectTotals.empty_entry)
    end

    it 'loads the whole page in one call' do
      expect(TimeSessions::SubjectTotals).to receive(:call).once.and_call_original

      described_class.new(user: user).preload([ticket, other_ticket])
    end
  end

  # Each ticket's time is read in its own project's scope, as its single lookup would read
  # it: a page is no promise of one project (review round 4 of #949).
  describe 'a page with tickets of two projects' do
    let(:second_project) { create(:project, organisation: organisation) }
    let(:foreign_ticket) { create(:ticket, project: second_project, organisation: organisation) }

    it 'answers each ticket from its own project, in one call per project' do
      book(on: ticket, minutes: 30)
      create(:time_session, project: second_project, organisation: organisation, creator: user,
                            ticket: foreign_ticket, duration: 45, occurred_on: 2.days.ago)
      page = [ticket, foreign_ticket]

      expect(TimeSessions::SubjectTotals).to receive(:call).twice.and_call_original
      # One query per project is the point here, and Prosopite reads two of the same shape as an
      # N+1. Bounded by the projects on a page; the ticket list shows one.
      cache = Prosopite.pause { described_class.new(user: user).preload(page) }

      expect(cache.fetch(ticket)).to include(minutes: 30)
      expect(cache.fetch(foreign_ticket)).to include(minutes: 45)
    end
  end

  describe 'a ticket the preload never saw' do
    it 'looks it up rather than reporting a zero' do
      book(on: other_ticket, minutes: 45)
      cache = described_class.new(user: user).preload([ticket])

      expect(cache.fetch(other_ticket)).to include(minutes: 45)
    end

    it 'works with no preload at all, which is how a single row re-renders' do
      book(on: ticket, minutes: 30)

      expect(described_class.new(user: user).fetch(ticket)).to include(minutes: 30)
    end

    it 'looks it up once and remembers the answer' do
      book(on: ticket, minutes: 30)
      cache = described_class.new(user: user)

      expect(TimeSessions::SubjectTotals).to receive(:call).once.and_call_original
      3.times { cache.fetch(ticket) }
    end
  end

  describe 'the rights tier' do
    let(:outsider) { create(:user) }

    before { create(:membership, user: outsider, organisation: organisation) }

    # Fail-closed all the way down: a user with no persisted permission row is
    # :none, and TimeSessions::ViewingScope#apply hands the loader an empty
    # relation, so a miss cannot leak a number either.
    it 'reports nothing to a user who may see none of the project\'s time' do
      book(on: ticket, minutes: 240)

      expect(described_class.new(user: outsider).fetch(ticket))
        .to eq(TimeSessions::SubjectTotals.empty_entry)
    end

    # The tier and the answers belong to one reader, so the cache is made for one (review
    # round 6 of #949): a cache that took the user per read would answer a second reader from
    # the first one's scope and entries.
    it 'answers for the reader it was made for, page or single lookup' do
      book(on: ticket, minutes: 240)
      book(on: other_ticket, minutes: 60)

      expect(described_class.new(user: user).preload([ticket]).fetch(ticket)).to include(minutes: 240)
      expect(described_class.new(user: outsider).preload([ticket]).fetch(ticket)).to eq(TimeSessions::SubjectTotals.empty_entry)
      expect(described_class.new(user: outsider).fetch(other_ticket)).to eq(TimeSessions::SubjectTotals.empty_entry)
    end

    # The answers, not only the scope: a single lookup by one reader is not what the next reader
    # gets (review round 8 of #949; a store shared across caches passed the example above).
    it "keeps one reader's single answers away from another reader's cache" do
      book(on: ticket, minutes: 240)

      expect(described_class.new(user: user).fetch(ticket)).to include(minutes: 240)
      expect(described_class.new(user: outsider).fetch(ticket)).to eq(TimeSessions::SubjectTotals.empty_entry)
    end

    it 'resolves the tier once per project, not once per ticket' do
      book(on: ticket)
      book(on: other_ticket)
      cache = described_class.new(user: user)

      expect(TimeSessions::ViewingScope).to receive(:call).once.and_call_original
      cache.fetch(ticket)
      cache.fetch(other_ticket)
    end
  end
end
