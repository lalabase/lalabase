# frozen_string_literal: true

require 'rails_helper'

# What the ticket list counts per row (booked time, sub-tickets, waiting) costs the same on a
# page of 3 as on a page of 25, on every surface that shows it. The column specs prove each
# count on its own; this proves the page as a whole, whatever a cell reads and whatever type
# its column has (third review of #949): the table with every column the picker offers, and
# the phone row with booked time, which shows it without any column being chosen.
#
# It guards the WHOLE page, not only the counts: any lookup made once per row turns it red,
# a policy check or a partial's own find as much as a count (review round 6). That is on
# purpose; the failure lists the queries that grew with the page.
RSpec.describe 'Ticket list: counted columns per page', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { ActsAsTenant.with_tenant(organisation) { create(:user) } }

  before do
    ActsAsTenant.current_tenant = organisation
    # An admin sees the project's booked time: the time columns are offered, the phone row
    # shows the time.
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def all_column_keys(project)
    ViewConfiguration.available_columns_for(project, 'tickets', user: user).pluck(:key)
  end

  # A project of its own with a page of `size` tickets that each have something to count:
  # booked time, a sub-ticket and a blocker. A page of nothing would pass by finding nothing.
  # The table shows every column the picker offers.
  def page_of(size)
    Prosopite.pause do
      @project = create(:project, organisation: organisation)
      ViewConfiguration.create!(user: user, project: project, view_type: 'tickets',
                                table_columns: all_column_keys(project),
                                list_columns: { 'cells' => [], 'metadata' => [] }, header_columns: %w[assignees])
      blocker = create(:ticket, project: project, creator: user)
      Array.new(size) do
        create(:ticket, project: project, creator: user).tap do |ticket|
          create(:ticket, project: project, creator: user, parent: ticket)
          create(:time_session, project: project, organisation: organisation, creator: user, ticket: ticket,
                                duration: 30, occurred_on: 2.days.ago)
          TicketRelation.create!(source_ticket: blocker, target_ticket: ticket, relation_type: :blocks)
        end
      end
    end
  end

  attr_reader :project

  def get_index(**params)
    get organisation_project_tickets_path(organisation, project, limit: 100, **params)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  # Queries sent to the database, and those Rails answered from its query cache. The second
  # number is the one that sees a repeated identical query: a page preload run again for
  # every row is the same SQL each time, and the query cache hides it from the first number
  # (review round 4 of #949).
  # Returns the two counts and, for the failure message, how often each statement ran.
  def queries(&)
    counts = { sent: 0, cached: 0 }
    statements = Hash.new(0)
    counter = lambda do |*, payload|
      next if payload[:name] == 'SCHEMA'

      counts[payload[:cached] ? :cached : :sent] += 1
      # One statement whatever the number of its values: Rails writes one as `= $1` and several
      # as `IN ($1, $2)`, and a preload of 3 and of 25 ids is the same statement. Keyed by the
      # whole statement; two that start alike stay apart.
      statements[payload[:sql].squish.gsub(/= \$\d+|IN \(\$\d+(?:, \$\d+)*\)/, 'IN ($n)')] += 1
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    [counts, statements]
  end

  # The statements run more often on the larger page, for the failure message.
  def grown(small, large)
    large.filter_map do |sql, count|
      "#{count - small[sql]}x more: #{sql.truncate(160)} [#{Digest::SHA1.hexdigest(sql)[0, 8]}]" if count > small[sql]
    end.join("\n")
  end

  # The first request of a page warms what is loaded once per process; the second is counted.
  # Prosopite is paused: four requests in one example repeat each request's own lookups, and
  # the counts are the stricter check here (the pages have 7 and 51 rows: one query more per
  # row is a difference of 44).
  def counted_request(**params)
    Prosopite.pause do
      get_index(**params)
      doc = nil
      count, statements = queries { doc = get_index(**params) }
      [count, doc, statements]
    end
  end

  it 'counts a table with every offered column in the same number of queries for 3 and 25 tickets' do
    counts = [3, 25].map do |size|
      page = page_of(size)
      expect(all_column_keys(project)).to include('time_spent', 'billing_status', 'subtask_count', 'waiting')
      count, doc, statements = counted_request
      row = doc.at_css("tr[data-ticket-id='#{page.first.id}']")
      expect(row.at_css("td[data-column='time_spent']").text.strip).to eq('00:30')
      expect(row.at_css("td[data-column='subtask_count']").text.strip).to eq('0/1')
      expect(row.at_css("td[data-column='waiting']").text.strip).to eq('1')
      expect(doc.css('tr[data-ticket-id]').size).to eq((2 * size) + 1)
      [count, statements]
    end

    expect(counts.map(&:first).uniq.size).to eq(1), lambda {
      "queries for 3 and 25 tickets: #{counts.map(&:first).inspect}\n#{grown(counts.first.last, counts.last.last)}"
    }
  end

  it 'counts a phone page with booked time in the same number of queries for 3 and 25 tickets' do
    counts = [3, 25].map do |size|
      page = page_of(size)
      count, doc, statements = counted_request(viewport: 'mobile')
      row = doc.at_css(".mobile-ticket-row[data-ticket-id='#{page.first.id}']")
      expect(row.at_css('.mobile-ticket-time').text.strip).to eq('00:30')
      expect(row.at_css('.ticket-waiting-mark')).to be_present
      expect(doc.css('.mobile-ticket-row[data-ticket-id]').size).to eq((2 * size) + 1)
      [count, statements]
    end

    expect(counts.map(&:first).uniq.size).to eq(1), lambda {
      "queries for 3 and 25 tickets: #{counts.map(&:first).inspect}\n#{grown(counts.first.last, counts.last.last)}"
    }
  end
end
