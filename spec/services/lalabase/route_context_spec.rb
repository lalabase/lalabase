# frozen_string_literal: true

require 'rails_helper'

# What: the routing context the citation links are built with.
#
# Why the assertions look the way they do: this guards a bug that rspec STRUCTURALLY
# cannot observe. `routes.url_helpers` is an ActiveSupport::Concern keeping
# ActionDispatch::Routing::UrlFor as a DEFERRED dependency. `include` runs Concern's
# append_features and pulls it in; `extend` never goes through append_features, so an
# extended object carries the generated path helpers WITHOUT the machinery they call
# (`optimize_routes_generation?`, `url_options`) and raises NoMethodError on every
# call. That shipped once: the assistant panel answered 500 on every cited message.
#
# Under rspec it looks fine either way, because the test environment mixes UrlFor into
# Object itself. An extended object borrows what it lacks. Worse, a correct class
# inherits it too: Ruby skips `include` for a module already in the ancestry, so even
# comparing ancestor positions proves nothing here. Calling a helper, checking
# respond_to?, reading the chain — all three are green on the broken code.
#
# So the load-bearing guard is the source assertion at the bottom, and the boot test
# in spec/services/lalabase/route_context_boot_spec.rb, which leaves the rspec process
# to reach an environment where Object is bare.
RSpec.describe Lalabase::RouteContext do
  subject(:context) { described_class.new }

  it 'includes the routing helpers rather than borrowing them' do
    expect(described_class.ancestors).to include(Rails.application.routes.url_helpers)
  end

  it 'carries this app own helper module, which the framework helpers do not' do
    expect(described_class.ancestors).to include(AssistantArtefactsHelper)
    expect(described_class.ancestors.index(AssistantArtefactsHelper))
      .to be < described_class.ancestors.index(Object)
  end

  # The two call shapes that broke differently: three positional arguments take the
  # optimized path (needs optimize_routes_generation?), a trailing hash takes the slow
  # path (needs url_options).
  it 'builds a path from positional arguments' do
    expect(context.organisation_project_ticket_path('o', 'p', 't'))
      .to eq('/org/o/projects/p/tickets/t')
  end

  it 'builds a path from a trailing hash' do
    expect(context.organisation_project_documentation_index_path('o', 'p', set_id: 's', page: 'x.md'))
      .to include('set_id=s')
  end

  # The guard that actually bites. Positive assertions cannot tell the two versions
  # apart in this process, so this one names the construction that broke.
  describe 'the construction itself' do
    it 'builds no routing context by extending a bare object anywhere in app/' do
      offending_files = Rails.root.glob('app/**/*.rb').select do |file|
        file.read.match?(/\.extend\(\s*Rails\.application\.routes\.url_helpers/)
      end
      offenders = offending_files.map { |file| file.relative_path_from(Rails.root).to_s }

      expect(offenders).to be_empty, lambda {
        "extend() skips ActiveSupport::Concern's append_features, so UrlFor never " \
        "arrives and every helper call raises in production:\n  " + offenders.join("\n  ")
      }
    end
  end
end
