# frozen_string_literal: true

# Which host shows which organisation (organisation subdomains, S2).
module Organisations
  # The one answer to "which host shows which organisation" (doc/org_subdomains_plan.md,
  # S2). The host never grants access: it only decides where a page is shown. Rights stay
  # the membership and policy checks of every request.
  #
  # Kinds of host, read by Lalabase::OrganisationHostGate and OrganisationHost:
  #   :off       organisation subdomains are switched off (no LALABASE_TENANT_DOMAIN)
  #   :main      the tenant domain itself, the instance's own host
  #   :elsewhere a host outside the tenant domain (an IP, localhost while testing)
  #   :current   the current subdomain of an organisation
  #   :held      an old subdomain an organisation still holds
  #   :unknown   below the tenant domain, and nobody's: no row, an expired hold, or more
  #              than one label deep
  class Hosts
    Place = Data.define(:kind, :organisation) do
      def organisation_host?
        kind == :current
      end
    end

    OFF = Place.new(kind: :off, organisation: nil)
    MAIN = Place.new(kind: :main, organisation: nil)
    ELSEWHERE = Place.new(kind: :elsewhere, organisation: nil)
    UNKNOWN = Place.new(kind: :unknown, organisation: nil)

    def self.call(**)
      new(**).call
    end

    def self.parent_domain
      Lalabase::InstanceSettings.tenant_domain
    end

    def self.enabled?
      parent_domain.present?
    end

    # The host the organisation's pages belong on: its current subdomain, else the main
    # host. nil while the feature is off.
    def self.host_for(organisation)
      domain = parent_domain
      return nil unless domain

      label = organisation.current_subdomain&.subdomain
      label ? "#{label}.#{domain}" : domain
    end

    def initialize(host:)
      @host = host.to_s.downcase
    end

    def call
      domain = self.class.parent_domain
      return OFF unless domain
      return MAIN if @host == domain

      suffix = ".#{domain}"
      return ELSEWHERE unless @host.end_with?(suffix)

      label = @host.delete_suffix(suffix)
      # Two labels deep (`a.kunde.lalabase.com`) is nobody's host.
      label.include?('.') ? UNKNOWN : place_for(label)
    end

    private

    def place_for(label)
      row = OrganisationSubdomain.includes(:organisation).find_by(subdomain: label)
      return UNKNOWN if row.nil?
      return Place.new(kind: :current, organisation: row.organisation) if row.current?
      return Place.new(kind: :held, organisation: row.organisation) if row.held_until.future?

      UNKNOWN
    end
  end
end
