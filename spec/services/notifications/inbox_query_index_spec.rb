# frozen_string_literal: true

require 'rails_helper'

# What: the two orders of the token inbox (Notifications::InboxQuery#relation)
#       each have an index on the recipient and the time they cut and order on:
#       without `arrived_since`, Notification::HAPPENED_AT_SQL
#       (index_notifications_on_recipient_and_happened_at); with it, the column
#       last_event_at (index_notifications_on_recipient_and_last_event_at).
# Why:  PostgreSQL uses an expression index only for the same expression. The
#       default order of the token inbox, what every client of API 1.15 polls,
#       had no index until 2026-11-27 and sorted every row of the recipient on
#       each call. A HAPPENED_AT_SQL that changes without its index (or the
#       other way round) turns this red.
# How:  EXPLAIN of the real relation, with sequential scans and sorts switched off
#       for the transaction, so the question is whether an index CAN serve the
#       cut and the order, not which plan the statistics of the moment favour (a
#       table of a few rows is read whole, and with statistics another index and
#       a sort can be cheaper; both made a first version of this spec flaky). The
#       index must carry the time cut in its Index Cond: an index that only
#       narrows to the recipient does not serve the cursor.
RSpec.describe Notifications::InboxQuery, 'indexes of its two orders' do
  let(:user) { create(:user) }
  let(:organisation) { create(:organisation) }
  let(:token) { create(:personal_access_token, user: user, organisations: [organisation]) }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, active: true)
      create(:notification, recipient: user, organisation: organisation, state: 'queued')
    end
  end

  # The query reads without a tenant, as #page runs it.
  def plan(**cursor)
    connection = ActiveRecord::Base.connection
    ActsAsTenant.without_tenant do
      relation = described_class.new(user: user, reach: token.reach, status: 'all', **cursor).relation.limit(50)
      connection.transaction(requires_new: true) do
        connection.execute('SET LOCAL enable_seqscan = off')
        connection.execute('SET LOCAL enable_sort = off')
        connection.select_values("EXPLAIN #{relation.to_sql}").join("\n")
      end
    end
  end

  # An index scan of `index` whose Index Cond cuts on `time` (the expression as
  # PostgreSQL prints it, without the table name).
  def cut_by_index(index, time)
    /Index Scan(?: Backward)? using #{index} on notifications.*\n\s*Index Cond: .*\(?#{Regexp.escape(time)}\)? > /
  end

  it 'reads the default order and its since by the index on when the latest event happened' do
    time = Notification::HAPPENED_AT_SQL.gsub('notifications.', '')

    expect(plan(since: 1.day.ago.iso8601)).to match(cut_by_index('index_notifications_on_recipient_and_happened_at', time))
  end

  it 'reads the order by arrival and its arrived_since by the index on last_event_at' do
    expect(plan(arrived_since: 1.day.ago.iso8601))
      .to match(cut_by_index('index_notifications_on_recipient_and_last_event_at', 'last_event_at'))
  end
end
