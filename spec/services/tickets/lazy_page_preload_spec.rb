# frozen_string_literal: true

require 'rails_helper'

# The page a list registers with a count cache (reviews 3, 4 and 6 of #949): registering costs
# nothing, the first read of any ticket on the page loads the whole page once, and a ticket on
# no page is left to the cache's own single lookup. The module wraps the cache's fetch itself
# (prepend), so a cache cannot forget to call it. The caches' own specs prove the numbers; the
# request specs (ticket_counted_columns_queries_spec.rb and the column specs) prove the pages.
RSpec.describe Tickets::LazyPagePreload do
  # A cache the size of the contract: it says whether a ticket is answered (answered?), a
  # preload that answers every ticket it is given and records its calls, a fetch(ticket) that
  # knows nothing of pages. Each answer names the load it came from. Its answers are not in
  # @entries on purpose: the module asks, it does not read a cache's store.
  let(:cache_class) do
    Class.new do
      prepend Tickets::LazyPagePreload

      attr_reader :preloads

      def initialize
        @preloads = []
        @answers = {}
      end

      def preload(tickets)
        @preloads << tickets.map(&:id)
        tickets.each { |ticket| @answers[ticket.id] = [:from_page, @preloads.size] }
        self
      end

      def fetch(ticket)
        return :no_id if ticket.id.nil?

        @answers[ticket.id] ||= [:on_its_own]
      end

      private

      def answered?(ticket_id)
        @answers.key?(ticket_id)
      end
    end
  end

  let(:cache) { cache_class.new }
  let(:ticket_class) { Struct.new(:id) }
  let(:page) { Array.new(3) { |index| ticket_class.new("page-#{index}") } }

  it 'loads nothing while nothing is read' do
    cache.register(page)

    expect(cache.preloads).to be_empty
  end

  it 'loads the whole page on the first read of any ticket on it' do
    cache.register(page)

    expect(cache.fetch(page[1])).to eq([:from_page, 1])
    expect(cache.preloads).to eq([page.map(&:id)])
  end

  it 'loads a page once, however many of its tickets are read' do
    cache.register(page)

    page.each { |ticket| cache.fetch(ticket) }
    cache.fetch(page.first)

    expect(cache.preloads.size).to eq(1)
  end

  it 'leaves a ticket on no page to its own lookup, and keeps the page for its own tickets' do
    cache.register(page)

    expect(cache.fetch(ticket_class.new('stray')).first).to eq(:on_its_own)
    expect(cache.preloads).to be_empty
    expect(cache.fetch(page.last).first).to eq(:from_page)
  end

  it 'loads only the page that holds the ticket read' do
    other = [ticket_class.new('other')]
    cache.register(page).register(other)

    cache.fetch(other.first)

    expect(cache.preloads).to eq([['other']])
  end

  it 'registers no page for tickets without an id, and hands such a ticket to the cache' do
    cache.register([ticket_class.new(nil)])

    expect(cache.fetch(ticket_class.new(nil))).to eq(:no_id)
    expect(cache.preloads).to be_empty
  end

  # Two pages that share a ticket: the ticket is answered once, and the second page loads only
  # its own tickets when one of them is read. The first answer is never overwritten.
  it 'loads a shared ticket with the first page only, and keeps its first answer' do
    shared = page.first
    second = [shared, ticket_class.new('second-only')]
    cache.register(page).register(second)

    expect(cache.fetch(shared)).to eq([:from_page, 1])
    cache.fetch(second.last)

    expect(cache.fetch(shared)).to eq([:from_page, 1])
    expect(cache.preloads).to eq([page.map(&:id), ['second-only']])
  end

  it 'loads nothing for a ticket read on its own before its page came, and keeps that answer' do
    early = page.first
    early_answer = cache.fetch(early)
    cache.register(page)

    expect(cache.fetch(early)).to eq(early_answer)
    expect(cache.preloads).to be_empty
    cache.fetch(page.last)
    expect(cache.preloads).to eq([page.drop(1).map(&:id)])
  end

  describe 'the count caches of the ticket list' do
    let(:organisation) { create(:organisation) }
    let(:project) { create(:project, organisation: organisation) }
    let(:user) { create(:user) }
    let(:tickets) { Array.new(3) { create(:ticket, project: project, organisation: organisation) } }

    before do
      ActsAsTenant.current_tenant = organisation
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    end

    after { ActsAsTenant.current_tenant = nil }

    def queries(&)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == 'SCHEMA' }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
      count
    end

    # How each cache is made: the time cache belongs to one reader, the other two to nobody.
    builders = {
      TimeSessions::SubjectTotalsCache => ->(user) { TimeSessions::SubjectTotalsCache.new(user: user) },
      Tickets::SubtaskCountsCache => ->(_user) { Tickets::SubtaskCountsCache.new },
      Tickets::WaitingCountsCache => ->(_user) { Tickets::WaitingCountsCache.new }
    }

    # The list above is written by hand; this keeps it whole. Every class that has the module
    # among its ancestors counts, whether it prepends it, includes it by mistake (then the module's
    # fetch never runs) or inherits it from a cache (then its own fetch may skip the module): each
    # turns red here until it has an example and the module first in its ancestors.
    it 'has an example for every cache that carries the module, and each prepends it' do
      Rails.application.eager_load!
      # Module#name, not klass.name: some class of the app redefines name with keywords. A class
      # without a name is a spec's fake, like the one above.
      named = Module.instance_method(:name)
      carriers = ObjectSpace.each_object(Class).select do |klass|
        klass < described_class && named.bind_call(klass)
      end

      expect(carriers).to match_array(builders.keys)
      carriers.each do |klass|
        expect(klass.ancestors.first).to eq(described_class), "#{klass} does not prepend #{described_class}"
        expect(klass.private_method_defined?(:answered?)).to be(true), "#{klass} has no private answered?"
      end
    end

    builders.each do |klass, build|
      # The wiring of the real cache, not of the fake above: registered, the first read loads
      # the page, and every other ticket on it is answered without a query.
      it "answers a registered page from one load in #{klass}" do
        cache = build.call(user).register(tickets)

        Prosopite.pause { cache.fetch(tickets.first) }

        expect(queries { tickets.drop(1).each { |ticket| cache.fetch(ticket) } }).to eq(0)
        expect(klass.ancestors.first).to eq(described_class)
      end

      # The real answered?, in the direction the page above cannot see: a ticket answered on its
      # own before the page came stays out of it, so reading it again costs nothing.
      it "keeps a ticket answered before its page out of the page in #{klass}" do
        cache = build.call(user)
        Prosopite.pause { cache.fetch(tickets.first) }
        cache.register(tickets)

        expect(queries { cache.fetch(tickets.first) }).to eq(0)
      end
    end
  end
end
