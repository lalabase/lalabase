# frozen_string_literal: true

module Provisioning
  # Minimal request-shaped value object for UserActivity.track!, which reads
  # remote_ip, user_agent and session.id. A provisioning call has no browser
  # session, but it carries the visitor the website acts for, and that visitor
  # belongs in the registration audit row rather than the website's own address.
  class RequestContext
    Session = Data.define(:id)

    attr_reader :remote_ip, :user_agent, :session

    def initialize(remote_ip:, user_agent: nil)
      @remote_ip = remote_ip
      @user_agent = user_agent
      @session = Session.new(nil)
    end
  end
end
