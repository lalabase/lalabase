# frozen_string_literal: true

module ComponentSessionShim
  # Avoid ActionDispatch::TestProcess#session recursion in component specs
  def session
    @__component_fake_session ||= {}
  end
end

RSpec.configure do |config|
  config.include ComponentSessionShim, type: :component
end
