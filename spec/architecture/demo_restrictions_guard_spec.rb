# frozen_string_literal: true

require 'rails_helper'

# The list of what the public demo refuses (DemoRestrictions::BLOCKED) is only
# worth something while each entry still reaches a request. A renamed controller,
# a removed action, or a controller that stops inheriting the check would leave
# an entry that blocks nothing and reads as if it did.
RSpec.describe DemoRestrictions, :ci_guard, type: :model do
  let(:routed) do
    # Routes load lazily in test.
    Rails.application.reload_routes_unless_loaded
    Rails.application.routes.routes.filter_map do |route|
      controller, action = route.defaults.values_at(:controller, :action)
      [controller, action] if controller && action
    end
  end

  described_class::BLOCKED.each do |controller_path, actions|
    describe controller_path do
      let(:controller_class) { "#{controller_path.camelize}Controller".constantize }
      let(:routed_actions) { routed.select { _1.first == controller_path }.map(&:last).uniq }

      it 'names a routed action for every entry' do
        expect(routed_actions).not_to be_empty
        expect(routed_actions).to include(*actions) unless actions == described_class::ALL
      end

      it 'runs the check' do
        expect(controller_class.ancestors).to include(described_class)
        expect(controller_class._process_action_callbacks.map(&:filter)).to include(:refuse_in_demo)
      end
    end
  end

  # A skip limited to some actions would leave the callback in the chain above and
  # still turn an entry off. No controller skips it at all. A tripwire: it reads
  # the source.
  it 'is skipped nowhere' do
    sources = Rails.root.glob('{app,lib}/**/*.rb').map(&:read)
    expect(sources.grep(/skip_(before_)?action\s*:refuse_in_demo/)).to be_empty
  end

  it 'answers per action' do
    expect(described_class.blocked?('users/registrations', 'update')).to be(true)
    expect(described_class.blocked?('users/registrations', 'edit')).to be(false)
    expect(described_class.blocked?('users/personal_access_tokens', 'index')).to be(true)
    expect(described_class.blocked?('organisations/tickets', 'create')).to be(false)
  end
end
