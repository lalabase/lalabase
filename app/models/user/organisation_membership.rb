# frozen_string_literal: true

class User < ApplicationRecord
  # Organisation-membership query helpers for User (user.rb split, slice 7/7).
  #
  # These methods answer "is this user a (active) member of org X?" and "what is
  # their role there?". Like slices 5 and 6 this is a behaviour Concern mixed
  # BACK INTO User: the methods stay instance methods on User, so every call site
  # keeps working unchanged with zero migration. Pure refactoring; behaviour is
  # bit-identical to the legacy User code this file replaces.
  #
  # CROSS-TENANT BY DESIGN. User is deliberately NOT acts_as_tenant (a user can
  # belong to many organisations) and neither is Membership, so these lookups run
  # cross-tenant on purpose. They must NOT be "improved" into tenant-scoped
  # queries — the cross-org reach is the whole reason membership lookups live here
  # rather than behind a tenant default scope. The memberships.loaded? branch in
  # member_of_organisation? / role_in_organisation (in-memory detect vs. find_by)
  # is likewise deliberate and preserved verbatim.
  #
  # REQUEST-LEVEL CACHES (the real risk of this move). role_in_organisation and
  # active_member_of_organisation? memoise per User instance, keyed by org id, in
  # @role_cache / @active_member_cache. Both are called per-org / per-project in
  # policies, the sidebar and the navigation; without the memo each call would
  # re-fire a membership query (silent N+1, the same trap as the org-count memo
  # in slice 3). The memos are pinned by query-count specs in
  # spec/models/user/organisation_membership_spec.rb.
  #
  # SCOPE NOTE: Admin::User is a SEPARATE class (same users table, no Devise, no
  # acts_as_tenant) with its OWN role_in_organisation that takes an organisation_id
  # rather than an object. That copy is deliberately NOT unified here and
  # Admin::User does NOT include this concern; this concern is included ONLY in User.
  module OrganisationMembership
    extend ActiveSupport::Concern

    def member_of_organisation?(organisation)
      org_id = organisation.is_a?(Organisation) ? organisation.id : organisation
      if memberships.loaded?
        memberships.any? { |m| m.organisation_id == org_id }
      else
        memberships.where(organisation_id: org_id).exists?
      end
    end

    def active_member_of_organisation?(organisation)
      # Request-level cache: same org asked repeatedly per request must hit the DB
      # once. Keyed by org id; only truthy results are memoised (||=), which is
      # the existing behaviour and intentionally left unchanged.
      @active_member_cache ||= {}
      org_id = organisation.is_a?(Organisation) ? organisation.id : organisation

      # org_id, not organisation.id: the line above accepts an id as well, and this
      # one raised NoMethodError on it while pretending otherwise.
      @active_member_cache[org_id] ||= memberships.active.where(organisation_id: org_id).exists?
    end

    def active_memberships
      memberships.active
    end

    def active_organisations
      organisations.merge(Membership.active)
    end

    # Resolve the user's role in an organisation (accepts an Organisation or its id).
    def role_in_organisation(organisation)
      # Request-level cache, keyed by org id. Uses key? rather than ||= so that a
      # nil result ("no role in this org") is cached too and not re-queried on the
      # next call — important because the policies hit this for users that have no
      # role just as often as for users that do.
      @role_cache ||= {}
      org_id = organisation.is_a?(Organisation) ? organisation.id : organisation

      return @role_cache[org_id] if @role_cache.key?(org_id)

      @role_cache[org_id] = begin
        membership = if memberships.loaded?
                       memberships.detect { |m| m.organisation_id == org_id }
                     else
                       memberships.find_by(organisation_id: org_id)
                     end
        membership&.role
      end
    end
  end
end
