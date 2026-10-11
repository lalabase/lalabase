# frozen_string_literal: true

# The curated throw-away mail domains from config/disposable_email_domains.yml.
#
# Entry point: DisposableEmailDomains.match?(email)
#
# A plain module rather than a validation on User on purpose: this rule belongs
# to ONE path, self-registration. Invitations, the Codebase import and the seeds
# all create users too, and none of them should be able to fail on the address
# of somebody who was deliberately invited.
module DisposableEmailDomains
  SOURCE = Rails.root.join('config/disposable_email_domains.yml')

  class << self
    def match?(email)
      # chomp('.') normalises the root-anchored FQDN form: "mailinator.com."
      # resolves to the same MX as "mailinator.com" and passes Devise's e-mail
      # regexp, but without this it matches neither the exact nor the subdomain
      # branch below and slips straight through.
      domain = email.to_s.downcase.strip.split('@').last&.chomp('.')
      return false if domain.blank?

      # Subdomains count: a service that hands out mail.temp.example addresses
      # is the same service as temp.example, and listing every subdomain would
      # be a losing race.
      all.any? { |listed| domain == listed || domain.end_with?(".#{listed}") }
    end

    # Memoised for the life of the process; editing the YAML needs a restart.
    # Eager-loaded at boot (config/initializers/disposable_email_domains.rb) so a
    # broken or empty file surfaces on deploy, not as a 500 on the first visitor
    # or as a silently disabled filter discovered weeks later.
    def all
      @all ||= load_domains
    end

    private

    def load_domains
      domains = Set.new(Array(YAML.safe_load_file(SOURCE)).map { |d| d.to_s.downcase.strip }.reject(&:blank?)).freeze
      # An empty list is fail-open: the filter is only one of several defences,
      # so it must not raise, but it must be loud -- an empty file would
      # otherwise wave every throw-away address straight through.
      Rails.logger.warn('[DisposableEmailDomains] list is empty; throw-away filter effectively disabled') if domains.empty?
      domains
    rescue StandardError => e
      # A malformed YAML must not turn the public sign-up into a 500. Log and
      # fail open; the boot-time eager load makes this visible on deploy.
      Rails.logger.error("[DisposableEmailDomains] could not load #{SOURCE}: #{e.class}: #{e.message}")
      Set.new.freeze
    end
  end
end
