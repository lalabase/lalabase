# frozen_string_literal: true

require 'rails_helper'

# Regression guard against the N+1 query on the time-session index.
#
# What is tested: the number of SQL SELECTs on `time_session_groups`
# while `GET .../time_sessions` is rendered.
# Type: request spec with an SQL counter via ActiveSupport::Notifications
#       ('sql.active_record') — analogous to time_session_statistics_service_spec.
# Why (philosophy): The row partial `_session_row` accesses
#   `time_session.time_session_group` (belongs_to) PER ROW (`.present?`, `.billed?`,
#   `.name`). Without eager loading this produces one belongs_to query per
#   row (`WHERE "time_session_groups"."id" = $1`) — i.e. N+1. With eager loading
#   (preload) the group is loaded in bulk (`... "id" IN ($1,$2,$3)`) and
#   served from the cache during rendering → 0 individual queries.
#   Contract: pure eager loading. NO behaviour/feature change — only the
#   query count drops; the list renders the same rows unchanged.
#
# Robustness: The hard N+1 proof is that the query count does NOT grow with the
# row count (three vs. five sessions/groups).
RSpec.describe 'Organisations::TimeSessions Query-Count (N+1 auf time_session_group)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  # Anchor in the current month so that the sessions are captured by the default
  # period ('this_month'). Start of month + 10 days keeps distance from both month edges.
  let(:month_anchor) { Time.current.beginning_of_month + 10.days }

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
    # Prosopite would raise in the test env on the deliberately produced N+1 (red phase).
    allow(Prosopite).to receive(:scan).and_yield
    allow(Prosopite).to receive(:finish)
  end

  # Creates `count` sessions in the given project, each with ITS OWN
  # time_session_group (distinct → preload uses an IN query, not `= $1`),
  # billed=false + group set ⇒ status 'in_billing' ⇒ visible in the default filter.
  def seed_sessions(target_project, count)
    Array.new(count) do |i|
      group = create(:time_session_group, organisation: organisation, creator: user)
      create(:time_session,
             organisation: organisation,
             project: target_project,
             creator: user,
             time_session_group: group,
             billed: false,
             occurred_on: month_anchor + i.hours)
      group
    end
  end

  # Captures all SQL statements during the block (without SCHEMA/TRANSACTION/CACHE).
  def capture_sql(&block)
    statements = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      next if %w[SCHEMA TRANSACTION CACHE].include?(payload[:name])

      statements << payload[:sql]
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &block)
    statements
  end

  # Per-row belongs_to queries (the N+1 signature): SELECT on
  # time_session_groups with equality on the id. Preload uses IN(...) and therefore
  # does NOT fall into this set.
  def group_row_lookups(statements)
    statements.select do |sql|
      sql =~ /from\s+"time_session_groups"/i && sql =~ /"time_session_groups"\."id"\s*=\s*\$/i
    end
  end

  # Per-row tag_list queries: `_session_row` calls `time_session.tag_list` per row,
  # which — when the `tags` association is not loaded — executes `tags.pluck(:name)`
  # (Taggable#tag_list), i.e. one query per row with `taggings.taggable_id = $1`.
  # Preload (`includes(:tags)`) collects via `taggable_id IN (...)` and therefore does NOT
  # fall into this set.
  def tag_row_lookups(statements)
    statements.select do |sql|
      sql =~ /from\s+"tags"/i && sql =~ /"taggings"\."taggable_id"\s*=\s*\$/i
    end
  end

  describe 'GET index' do
    it 'laedt time_session_group nicht pro Zeile (kein N+1)' do
      project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      groups = seed_sessions(project, 3)

      statements = capture_sql do
        get organisation_time_sessions_path(organisation, project_id_filter: project.id)
      end

      # The list must actually render rows, otherwise the test is worthlessly green.
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(groups.first.name)

      # Before the fix: 3 individual queries (one per row). After the fix: 0 (preload).
      expect(group_row_lookups(statements).size).to be <= 1
    end

    it 'skaliert nicht mit der Zeilenzahl (robuster N+1-Beweis)' do
      project_small = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      project_large = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      seed_sessions(project_small, 3)
      seed_sessions(project_large, 5)

      small_statements = capture_sql do
        get organisation_time_sessions_path(organisation, project_id_filter: project_small.id)
      end
      expect(response).to have_http_status(:ok)

      large_statements = capture_sql do
        get organisation_time_sessions_path(organisation, project_id_filter: project_large.id)
      end
      expect(response).to have_http_status(:ok)

      # The number of time_session_group individual queries must NOT grow with more
      # rows. Before the fix: 3 vs. 5. After the fix: 0 vs. 0.
      expect(group_row_lookups(large_statements).size).to eq(group_row_lookups(small_statements).size)
    end

    it 'laedt tag_list nicht pro Zeile (kein N+1 auf tags)' do
      project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      groups = seed_sessions(project, 3)

      statements = capture_sql do
        get organisation_time_sessions_path(organisation, project_id_filter: project.id)
      end

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(groups.first.name)

      # Before the fix: 3 tag_list individual queries (one per row). After the fix: 0 (preload).
      expect(tag_row_lookups(statements).size).to be <= 1
    end
  end
end
