# frozen_string_literal: true

require 'rails_helper'

# N+1 guard for the billing views after the "Bezug" rework.
#
# What is tested: the total number of SQL SELECTs while the three billing views
# render, measured against a row count that doubles.
#
# Why (philosophy): the "Bezug" cell (_subject_cell) does two things per row that
# the previous markup did not. It reads `subject.project` to build the link, and
# it asks `policy(subject.project).area_access?(...)` whether the viewer may follow
# it. The second one is the dangerous half: ProjectPolicy#area_access? falls
# through to AccessCheck::ProjectAccessService, whose #initialize runs a
# find_project_permission query. One policy per row would mean one permission
# query per row.
#
# Two things are supposed to prevent that: `includes(ticket: :project, meeting:
# :project)` in #load_time_sessions, and Pundit's per-request policy cache, which
# is keyed by record — and ActiveRecord defines #hash/#== by id, so two separately
# preloaded instances of the SAME project share one cached policy.
#
# The viewer here is deliberately NOT an account admin: #area_access? returns
# early for admins and would never reach the service, hiding exactly the N+1 this
# guards. The hard proof is that the count does not grow with the row count.
RSpec.describe 'Organisations::TimeSessionGroups Query-Count (N+1 in der Bezug-Spalte)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:user) { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let!(:project_permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: user, project: project,
                                  tickets_access: :read_only, meetings_access: :read_only)
    end
  end

  let!(:time_permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session_permission, user: user, project: project,
                                       can_create_own: true, can_view_own: true, can_view_all: true)
    end
  end

  let(:time_session_group) do
    ActsAsTenant.with_tenant(organisation) { create(:time_session_group, organisation: organisation, creator: user) }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  # Builds `count` sessions, alternating ticket and meeting subjects so both
  # branches of the cell are exercised, each on its own subject record.
  def seed_sessions(count)
    ActsAsTenant.with_tenant(organisation) do
      count.times do |i|
        subject_attrs = if i.even?
                          { ticket: create(:ticket, project: project, organisation: organisation, creator: user) }
                        else
                          { meeting: create(:meeting, project: project, organisation: organisation, creator: user) }
                        end
        create(:time_session, { organisation: organisation, time_session_group: time_session_group,
                                project: project, creator: user }.merge(subject_attrs))
      end
    end
  end

  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_, _, _, _, payload|
      count += 1 unless payload[:name].to_s.in?(%w[SCHEMA TRANSACTION]) || payload[:sql].start_with?('BEGIN', 'COMMIT')
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  %i[chronological aggregated customer_export].each do |view|
    it "hält die Query-Zahl in #{view} konstant, wenn sich die Zeilenzahl verdoppelt" do
      seed_sessions(4)
      small = count_queries { get send("#{view}_organisation_time_session_group_path", organisation, time_session_group) }
      expect(response).to have_http_status(:ok)

      seed_sessions(4) # now 8 rows over 8 distinct subjects
      large = count_queries { get send("#{view}_organisation_time_session_group_path", organisation, time_session_group) }
      expect(response).to have_http_status(:ok)

      # A per-row permission lookup would add at least four queries here. A small
      # tolerance keeps the guard from tripping on unrelated per-page work.
      expect(large).to be <= small + 2,
                       "Query-Zahl waechst mit den Zeilen (#{small} -> #{large}) — pro Zeile eine Policy/Permission-Abfrage?"
    end
  end
  # P1 of the billings redesign: the index used to run the count/sum pair per
  # row IN THE VIEW (two queries per billing). The controller now answers both
  # from one grouped, policy-scoped query each, so the total may not grow with
  # the row count. The viewer is an account admin because #index is
  # admin/finance-only (TimeSessionGroupPolicy#index?).
  describe 'index (Summen je Zeile aus gebuendelten Queries)' do
    let(:admin_user) { create(:user) }
    let(:admin_role) { create(:admin_role, organisation: organisation) }
    let!(:admin_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: admin_user, organisation: organisation, role: admin_role, active: true)
      end
    end

    before { sign_in admin_user }

    def seed_groups(count)
      ActsAsTenant.with_tenant(organisation) do
        count.times do
          group = create(:time_session_group, organisation: organisation, creator: user)
          create(:time_session, organisation: organisation, time_session_group: group,
                                project: project, creator: user)
        end
      end
    end

    it 'haelt die Query-Zahl im Index konstant, wenn sich die Zeilenzahl verdoppelt' do
      seed_groups(3)
      small = count_queries { get organisation_time_session_groups_path(organisation) }
      expect(response).to have_http_status(:ok)

      seed_groups(3) # now 6 rows
      large = count_queries { get organisation_time_session_groups_path(organisation) }
      expect(response).to have_http_status(:ok)

      expect(large).to be <= small + 2,
                       "Query-Zahl waechst mit den Zeilen (#{small} -> #{large}) -- Summe/Zaehler oder Policy pro Zeile statt gebuendelt?"
    end
  end
end
