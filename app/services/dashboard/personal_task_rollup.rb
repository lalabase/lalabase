# frozen_string_literal: true

module Dashboard
  # Cross-org roll-up of the user's OWN open personal to-dos for the cockpit
  # (organisations#select). Read-only glance; triage happens in the Notizblock drawer.
  #
  # Strictly user-private: every per-org read is scoped to where(user: current_user) on top of
  # acts_as_tenant, so an org admin never sees another user's to-dos. Same per-tenant iteration
  # as Dashboard::CrossOrgActionSummary — over the user's ACTIVE orgs, one PersonalTask read per
  # org inside that org's tenant (the repeated SQL is the intentional per-tenant loop; see
  # spec/support/prosopite.rb). No Rails.cache; memoised per request.
  class PersonalTaskRollup
    def initialize(user:)
      @user = user
    end

    # [[organisation, [PersonalTask, ...]], ...] for orgs with >= 1 open to-do, in the user's
    # active-org order. Orgs with nothing open drop out (the cockpit does not nag).
    def slices
      @slices ||= user.active_organisations.filter_map do |organisation|
        tasks = personal_tasks_for_org(organisation)
        [organisation, tasks] if tasks.any?
      end
    end

    delegate :any?, to: :slices

    def total
      @total ||= slices.sum { |(_organisation, tasks)| tasks.size }
    end

    private

    attr_reader :user

    def personal_tasks_for_org(organisation)
      ActsAsTenant.with_tenant(organisation) do
        # where(user:) is the owner-private scope (stronger than tenant scoping) — never another
        # user's to-dos, not even for an org admin.
        PersonalTask.where(user: user).open.ordered.to_a
      end
    end
  end
end
