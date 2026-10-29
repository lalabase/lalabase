# frozen_string_literal: true

require 'rails_helper'

# What: every write route of /api/v1 honours the Idempotency-Key header
#   (`idempotent :action` in its controller, Api::V1::Idempotent).
# Why: /api/v1/me promises the `idempotency` capability for every write. A new
#   POST or PATCH that forgets `idempotent` would ignore the header silently, and
#   a client that trusts the promise would write twice on a retry. A promise a
#   new endpoint has to remember is not kept, so this guard keeps it.
RSpec.describe 'API V1 writes are idempotent', :ci_guard do
  let(:write_routes) do
    Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller].to_s
      next unless controller.start_with?('api/v1/')
      next if route.verb.blank? || %w[GET HEAD].include?(route.verb)

      [controller, route.defaults[:action].to_s, "#{route.verb} #{route.path.spec}"]
    end
  end

  it 'finds the write routes it is meant to cover' do
    expect(write_routes.map(&:first).uniq).to include('api/v1/tickets', 'api/v1/posts', 'api/v1/notifications')
  end

  it 'declares every write action idempotent' do
    missing = write_routes.reject do |controller, action, _|
      "#{controller.camelize}Controller".constantize.idempotent_actions.include?(action.to_sym)
    end
    expect(missing.map(&:last)).to be_empty
  end
end
