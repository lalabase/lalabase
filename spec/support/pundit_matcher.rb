# frozen_string_literal: true

# Custom RSpec matcher for Pundit policies
# This is a simple implementation to match what the gem pundit-matchers provides
RSpec::Matchers.define :permit_action do |action|
  match do |policy|
    policy.public_send("#{action}?")
  end

  failure_message do |policy|
    "#{policy.class} does not permit #{action} for #{policy.user.inspect}"
  end

  failure_message_when_negated do |policy|
    "#{policy.class} does not forbid #{action} for #{policy.user.inspect}"
  end
end

# Matcher for policy scopes
RSpec::Matchers.define :permit do |user, record|
  match do |policy_class|
    policy = policy_class.new(user, record)
    policy.public_send("#{@action}?")
  end

  chain :to do |action|
    @action = action
  end

  failure_message do |policy_class|
    "Expected #{policy_class} to permit #{@action} for #{user.inspect} on #{record.inspect}, but it doesn't"
  end

  failure_message_when_negated do |policy_class|
    "Expected #{policy_class} not to permit #{@action} for #{user.inspect} on #{record.inspect}, but it does"
  end
end

# Add support for the 'permissions' keyword in RSpec
module Pundit
  module RSpec
    module DSL
      def permissions(*args, &block)
        describe(args.first || 'permissions') do
          instance_eval(&block)
        end
      end
    end
  end
end

# Include the DSL module in RSpec example groups
RSpec.configure do |config|
  config.include Pundit::RSpec::DSL, type: :policy
end
