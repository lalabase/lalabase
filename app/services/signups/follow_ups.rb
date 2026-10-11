# frozen_string_literal: true

# The steps after a signup has committed (Actors::CreateSignup) that must never undo it:
# the onboarding tutorial, the acquisition source on the account, the founder discount
# request and the audit entry. Each step is rescued and logged on its own, so a failing
# one costs that one thing and the customer keeps account and organisation. The rescue
# lives here and not in the actor on purpose: the actor contract keeps the failure mapping
# in BaseActor#with_error_mapping, and none of these is a failure of the signup.
#
# Answers with the saved FounderSignup, or nil when none was requested or saving failed.
module Signups
  class FollowUps
    LOG_PREFIX = '[Registration]'

    def self.call(**)
      new(**).call
    end

    def initialize(user:, organisation:, acquisition: nil, founder_signup: nil, request: nil)
      @user = user
      @organisation = organisation
      @acquisition = acquisition
      @founder_signup = founder_signup
      @request = request
    end

    def call
      seed_onboarding
      attach_acquisition
      saved_founder_signup = attach_founder_signup
      track_registration
      saved_founder_signup
    end

    private

    # doc/onboarding_plan.md, failure-mode test: the user keeps account and organisation,
    # just without the tutorial project. The rescue also covers dev/test, where BaseActor
    # re-raises unexpected errors instead of returning a failed Result.
    def seed_onboarding
      result = Actors::SeedOnboarding.call(organisation: @organisation, current_user: @user)
      log("onboarding seed failed: #{result.errors.join(', ')}") unless result.success?
    rescue StandardError => e
      log("onboarding seed crashed: #{e.class}: #{e.message}")
    end

    # update_column deliberately: an analytics field on the billing entity must neither run
    # Account's validations (a half-filled account of a brand-new customer is normal here)
    # nor bump updated_at, which billing views read as "somebody changed the account".
    def attach_acquisition
      account = @organisation.account
      return if account.blank?

      source = AcquisitionSource.from_stored(@acquisition)
      return if source.nil?

      account.update_column(:acquisition, source.to_h)
    rescue StandardError => e
      log("acquisition capture failed: #{e.class}: #{e.message}")
    end

    # The operator mail waits for the outermost commit: this runs after the signup's
    # transaction today, but a caller wrapping the actor in its own transaction must not
    # mail about a request that rolls back.
    def attach_founder_signup
      return if @founder_signup.nil?
      return if @organisation.account.blank?

      @founder_signup.account = @organisation.account
      @founder_signup.save!
      founder_signup = @founder_signup
      ActiveRecord.after_all_transactions_commit { FounderSignupMailer.new_request(founder_signup).deliver_later }
      founder_signup
    rescue StandardError => e
      log("founder signup failed: #{e.class}: #{e.message}")
      nil
    end

    def track_registration
      @user.track_registration(request: @request, organisation: @organisation)
    rescue StandardError => e
      log("audit entry failed: #{e.class}: #{e.message}")
    end

    def log(message)
      Rails.logger.error("#{LOG_PREFIX} #{message}")
    end
  end
end
