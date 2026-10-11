# frozen_string_literal: true

module Subscriptions
  # Pure DETECTION query for Guest-Ceiling violations (Plan
  # doc/billing_agentur_konto_plan.md §4.3) -- never blocks a write, never
  # changes data. Surfaces which Users exceed the Account's configured guest
  # limits, for a non-blocking hint to the acting org-admin and for display in
  # the Lalabase Admin-Backend (§4.4). The only remaining HARD, blocking rule
  # from §4.3 is the Role/Permission Verbotsliste (s.
  # Role::FORBIDDEN_BILLABLE_FALSE_CATEGORIES) -- this class is intentionally
  # read-only and has no bearing on whether a write succeeds.
  #
  # Regel-Subjekt (Fund 1): a User only counts if they are EXCLUSIVELY a guest
  # across the whole Account (never billable: true anywhere in it) -- someone
  # billable anywhere is already a paid seat, regardless of guest footprint
  # elsewhere (s. Cross-Account-Isolation D4.1, which this mirrors within one
  # Account).
  #
  # Cross-org read via ActsAsTenant.with_tenant per organisation (D5-style),
  # deliberately not a raw without_tenant query -- Membership itself has
  # acts_as_tenant disabled (membership.rb:29), a documented, low-risk
  # deviation (read-only, no write path) from the D5 with_tenant convention.
  class GuestCeiling
    Violation = Struct.new(
      :user, :organisation_count, :organisation_limit,
      :project_counts_by_organisation, :project_limit,
      keyword_init: true
    ) do
      def over_organisation_limit?
        organisation_count > organisation_limit
      end

      def organisations_over_project_limit
        project_counts_by_organisation.select { |_, count| count > project_limit }
      end

      def any_limit_exceeded?
        over_organisation_limit? || organisations_over_project_limit.any?
      end
    end

    def initialize(account)
      @account = account
    end

    # Full sweep: every violating User in the Account. Used by the Admin-
    # Backend (§4.4, index badge + show page's violation list) -- there is no
    # way to avoid loading every organisation's full membership list here,
    # since the whole point is to report on ALL users at once.
    def violations
      billable_anywhere = Set.new
      project_counts_by_user = Hash.new { |h, k| h[k] = {} }

      account.organisations.each do |org|
        ActsAsTenant.with_tenant(org) do
          memberships = org.memberships.where(active: true).includes(:role)
          user_ids = memberships.map(&:user_id)

          memberships.each { |m| billable_anywhere << m.user_id if m.role&.billable }

          project_counts = ProjectPermission.where(user_id: user_ids, project: org.projects)
                                            .group(:user_id)
                                            .count

          user_ids.each do |user_id|
            project_counts_by_user[user_id][org] = project_counts.fetch(user_id, 0)
          end
        end
      end

      # One batched load for every violating user's User record, instead of a
      # separate User.find per violation below (N+1 as the violation count grows).
      violating_user_ids = project_counts_by_user.keys - billable_anywhere.to_a
      users_by_id = User.where(id: violating_user_ids).index_by(&:id)

      project_counts_by_user.filter_map do |user_id, project_counts_by_organisation|
        next if billable_anywhere.include?(user_id)

        # Nil-safe on purpose: a membership can reference a User row this
        # default-scoped query cannot see (soft-deleted user whose memberships
        # were not yet destroyed, or an orphaned membership -- memberships has
        # no FK on user_id). A missing User must degrade to "not reported",
        # never crash the Admin-Backend pages rendering this sweep.
        user = users_by_id[user_id]
        next unless user

        build_violation(user, project_counts_by_organisation)
      end
    end

    # Single-user check: used by the non-blocking hint
    # (Organisations::BaseController#warn_if_guest_ceiling_exceeded), which
    # runs on every membership/project-permission write, not just in the
    # Admin-Backend. Deliberately NOT implemented as `violations.find { ... }`
    # -- that would load and group every OTHER user's memberships/project
    # counts in the account just to throw the result away. Still one query
    # pair per organisation (the Account's org count is the unavoidable
    # lower bound, same as SeatCounter/D5), but never more than that.
    def violation_for(user)
      billable_anywhere = false
      project_counts_by_organisation = {}

      account.organisations.each do |org|
        ActsAsTenant.with_tenant(org) do
          membership = org.memberships.where(user_id: user.id, active: true).includes(:role).first
          next unless membership

          billable_anywhere = true if membership.role&.billable
          project_counts_by_organisation[org] =
            ProjectPermission.where(user_id: user.id, project: org.projects).count
        end
      end

      return nil if billable_anywhere || project_counts_by_organisation.empty?

      build_violation(user, project_counts_by_organisation)
    end

    private

    attr_reader :account

    def build_violation(user, project_counts_by_organisation)
      violation = Violation.new(
        user: user,
        organisation_count: project_counts_by_organisation.size,
        organisation_limit: account.guest_max_organisations,
        project_counts_by_organisation: project_counts_by_organisation,
        project_limit: account.guest_max_projects_per_organisation
      )

      violation if violation.any_limit_exceeded?
    end
  end
end
