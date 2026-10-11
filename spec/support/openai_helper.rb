# frozen_string_literal: true

RSpec.configure do |config|
  config.before(:each) do
    # Stub ChatResponseJob to prevent actual job execution and Redis errors
    allow(ChatResponseJob).to receive(:perform_later).and_return(true)
  end
end
