# frozen_string_literal: true

# Delivers every mail this app queues, and keeps its arguments out of the log.
#
# ActiveJob logs the arguments of an enqueued job at INFO, and Devise passes the
# raw token as an argument: reset_password_instructions, confirmation_instructions
# and unlock_instructions all hand it over in the clear. Measured before this
# class existed — the enqueue line carried the reset token verbatim, and anyone
# who could read the log could redeem it while it was still valid. Request
# parameter filtering does not help here: these are positional job arguments,
# not request parameters.
#
# Nothing of value is lost. The mail's contents were never in the log, and the
# job still names the mailer and the action; only the arguments are withheld.
class MailDeliveryJob < ActionMailer::MailDeliveryJob
  self.log_arguments = false
end
