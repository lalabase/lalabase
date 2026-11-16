# frozen_string_literal: true

# Sets, changes or removes the subdomain an organisation is shown under
# (doc/org_subdomains_plan.md, S1). Only the instance admin calls it; the admin area is
# Beuser-gated, so current_user is nil (as in Actors::CreateUserWithOrganisation).
#
# A name the organisation leaves is not freed at once: it is held for
# OrganisationSubdomain::HOLD_PERIOD, during which its old links still lead to the
# organisation and nobody else can take it. The organisation itself may take a held name
# back. A hold that has run out counts as absent and is deleted when someone takes the
# name.
module Actors
  class AssignOrganisationSubdomain < BaseActor
    def initialize(organisation:, subdomain:, current_user: nil)
      super()
      @organisation = organisation
      @label = subdomain.to_s.strip.downcase.presence
      @current_user = current_user
    end

    def record
      @organisation
    end

    def perform
      # One admin write at a time per organisation: the hold and the new row are two steps.
      @organisation.lock!
      current = @organisation.subdomains.current.first
      return if current&.subdomain == @label

      if @label
        OrganisationSubdomain.expired.where(subdomain: @label).delete_all
        @organisation.subdomains.where(subdomain: @label).delete_all
      end
      current&.update!(held_until: OrganisationSubdomain::HOLD_PERIOD.from_now)
      @organisation.subdomains.create!(subdomain: @label) if @label
      @organisation.association(:current_subdomain).reset
    end
  end
end
