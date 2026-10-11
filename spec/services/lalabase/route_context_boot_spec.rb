# frozen_string_literal: true

require 'rails_helper'

# What: builds a citation path in a SEPARATE Rails process.
# Why:  inside rspec this can never fail. The test environment mixes
#       ActionDispatch::Routing::UrlFor into Object, so a broken routing context
#       borrows the methods it is missing and every in-process assertion passes on
#       code that answers 500 in production. Leaving the process is the only way to
#       reach an environment where Object is bare, which is what a request has.
#
#       Costs one Rails boot (a few seconds). That is the price of an assertion that
#       can actually go red; the sibling spec explains why the cheap ones cannot.
RSpec.describe 'Lalabase::CitationLink in a bare process' do
  it 'builds a ticket path outside rspec, where Object carries no UrlFor' do
    script = <<~RUBY
      citation = { 'type' => 'ticket', 'id' => 'tid', 'project_id' => 'pid' }
      begin
        puts "RESULT:" + Lalabase::CitationLink.path_for(citation, organisation: 'oid').to_s
      rescue StandardError => e
        puts "RAISED:" + e.class.to_s + ": " + e.message
      end
    RUBY

    File.write(Rails.root.join('tmp/route_context_probe.rb'), script)
    output = `cd #{Rails.root} && RAILS_ENV=test bundle exec rails runner tmp/route_context_probe.rb 2>&1`

    expect(output).to include('RESULT:/org/oid/projects/pid/tickets/tid')
    expect(output).not_to include('RAISED:')
  ensure
    FileUtils.rm_f(Rails.root.join('tmp/route_context_probe.rb'))
  end
end
