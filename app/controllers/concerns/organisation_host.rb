# frozen_string_literal: true

# Shows an organisation's pages on its own host (doc/org_subdomains_plan.md, S2).
#
# The host never grants access. A page of organisation X is redirected to X's host only
# after the request has established that the person is an active member of X; a
# non-member gets what they got before, on whatever host they asked. Only full pages move:
# a frame, a stream, a write or a file is answered where it is asked, so nothing hops
# across origins halfway through a page.
#
# What the host gate in front of the controllers answers (unknown and old subdomains, the
# main host's doors) is Lalabase::OrganisationHostGate.
module OrganisationHost
  extend ActiveSupport::Concern

  included do
    before_action :show_organisation_on_its_host, if: :organisation_page_to_place?
  end

  private

  def organisation_host_place
    @organisation_host_place ||= request.env[Lalabase::OrganisationHostGate::ENV_KEY] ||
                                 Organisations::Hosts.call(host: request.host)
  end

  # The organisation of the request's host, if the person is an active member of it. The
  # start of a session on `kunde.lalabase.com` is that organisation, not the person's
  # first one.
  def host_organisation_for(user)
    return nil unless user

    place = organisation_host_place
    return nil unless place.organisation_host?
    return nil unless user.active_memberships.exists?(organisation_id: place.organisation.id)

    place.organisation
  end

  def organisation_page_to_place?
    Organisations::Hosts.enabled? && user_signed_in? && params[:organisation_id].present? &&
      full_page_request?
  end

  def show_organisation_on_its_host
    # Both are set by load_tenant_from_session, the membership only when it is active.
    return unless @current_organisation && @current_membership
    return unless @current_organisation.id.to_s == params[:organisation_id].to_s

    target = Organisations::Hosts.host_for(@current_organisation)
    return if target.nil? || target == request.host

    redirect_to "#{request.protocol}#{target}#{request.port_string}#{request.fullpath}",
                allow_other_host: true
  end
end
