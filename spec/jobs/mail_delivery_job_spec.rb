# frozen_string_literal: true

require 'rails_helper'

# Devise hands the raw token to the mailer as an ARGUMENT
# (reset_password_instructions, confirmation_instructions, unlock_instructions),
# and ActiveJob logs the arguments of an enqueued job at INFO. Before this job
# existed, the enqueue line carried a working password-reset token verbatim, and
# request parameter filtering does not reach it -- these are job arguments, not
# request parameters.
RSpec.describe MailDeliveryJob do
  def log_of_enqueue
    io = StringIO.new
    previous_logger = ActiveJob::Base.logger
    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.logger = ActiveSupport::Logger.new(io).tap { |logger| logger.level = Logger::INFO }
    token = yield
    [token, io.string]
  ensure
    ActiveJob::Base.logger = previous_logger
    ActiveJob::Base.queue_adapter = previous_adapter
  end

  it 'is the job every mail goes through' do
    expect(ActionMailer::Base.delivery_job).to eq(described_class)
  end

  it 'keeps a password reset token out of the log' do
    user = ActsAsTenant.without_tenant { create(:user) }

    token, log = log_of_enqueue { user.send_reset_password_instructions }

    expect(log).to include('Enqueued')
    expect(token).to be_present
    expect(log).not_to include(token)
  end

  it 'keeps a confirmation token out of the log' do
    user = ActsAsTenant.without_tenant { create(:user, :unconfirmed) }

    _token, log = log_of_enqueue { user.send_confirmation_instructions }

    expect(log).to include('Enqueued')
    expect(log).not_to include(user.reload.confirmation_token.to_s)
  end

  # Without this the guard above would also pass for a job that logs nothing at
  # all, including which mail it is about.
  it 'still says which mail it is delivering' do
    user = ActsAsTenant.without_tenant { create(:user) }

    _token, log = log_of_enqueue { user.send_reset_password_instructions }

    expect(log).to include('MailDeliveryJob')
  end
end
