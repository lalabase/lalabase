# frozen_string_literal: true

require 'rails_helper'

# Rack retires status symbols, and the test suite is the half nothing protects.
#
# Rack 3.1 renamed :unprocessable_entity to :unprocessable_content (and
# :payload_too_large to :content_too_large). 3.1 still resolved the old
# spellings silently; 3.2 resolves them through a private fallback table that
# prints a deprecation warning on every call and announces their removal.
#
# In the application this is invisible, but only from actionpack 8.0.5.1 on:
# ActionDispatch::Response.rack_status_code translates both directions before
# Rack is ever asked (action_dispatch/http/response.rb). Under 8.0.2 that method
# does not exist yet and `render status: :unprocessable_entity` goes straight
# through. So the 98 retired spellings still sitting in app/ and config/ are
# quiet because of a Rails version, not because they are current.
#
# The suite has no such layer in any combination. rspec-rails hands the symbol
# straight to Rack::Utils.status_code (have_http_status.rb:219), so once Rack
# 3.2 is in the lock every one of these calls warns per example -- and raises
# ArgumentError once Rack drops the fallback.
#
# That asymmetry is the whole point of this guard: those 98 controller call
# sites keep teaching the retired spelling, and a spec copied from them puts the
# warning right back with nothing to catch it.
#
# The rule is checked against DATA, not a hardcoded list of bad words. Rack's
# obsolete table is a private_constant and cannot be read; what can be read is
# the positive mapping every current symbol lives in. A symbol missing from
# SYMBOL_TO_STATUS_CODE is by definition one Rack no longer considers current --
# today :unprocessable_entity, tomorrow whatever gets retired next, with nobody
# having to come back and edit this file.
#
# ⚠️ Consequence of that choice: on a Rack older than 3.1 this guard turns red,
# because :unprocessable_content is not in the mapping there yet. That is the
# correct reading and not a false alarm -- the vocabulary in the specs genuinely
# would not match the installed Rack, and the matcher would raise. The failure
# message prints the Rack version for exactly this case.
RSpec.describe 'HTTP status symbols in the test suite', type: :model do
  # This file quotes the retired spelling on purpose, in the self-test below.
  # A guard that greps cannot tell a violation from an example OF one.
  let(:guard_itself) { Rails.root.join('spec/architecture/rack_status_symbol_guard_spec.rb').to_s }

  let(:spec_files) { Dir.glob(Rails.root.join('spec/**/*.rb')).reject { |path| path == guard_itself } }

  # Both matcher spellings, plus the Minitest form, in one expression:
  #   have_http_status(:ok) / have_http_status :ok / assert_response :ok
  # A numeric argument is nobody's business here -- 422 never gets deprecated.
  let(:status_symbol) { /(?:have_http_status|assert_response)\s*\(?\s*:([a-z_]+)/ }

  # [symbol, "path:line"] for every call site, so a failure names the file
  # instead of just the symbol.
  let(:call_sites) do
    spec_files.flat_map do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root).to_s

      File.readlines(path).each_with_index.filter_map do |line, index|
        match = line.match(status_symbol)
        [match[1].to_sym, "#{relative}:#{index + 1}"] if match
      end
    end
  end

  # rspec-rails accepts response CATEGORIES too (:success, :redirect, ...). Those
  # are not Rack status names and are absent from the mapping by design, so they
  # are read from rspec's own list rather than copied into one here.
  let(:generic_statuses) { RSpec::Rails::Matchers::HaveHttpStatus::GenericStatus.valid_statuses }

  it 'uses only symbols the installed Rack still recognises' do
    offenders = call_sites.reject do |symbol, _location|
      Rack::Utils::SYMBOL_TO_STATUS_CODE.key?(symbol) || generic_statuses.include?(symbol)
    end

    expect(offenders).to be_empty, <<~MESSAGE
      These status symbols are not in Rack::Utils::SYMBOL_TO_STATUS_CODE
      (rack #{Rack.release}). Rack resolves them through a deprecated fallback
      that warns on every example and is slated for removal; rspec-rails passes
      the symbol straight through, so the suite gets no protection from it.

      Use the current spelling -- :unprocessable_content for 422,
      :content_too_large for 413. The number is unchanged either way.

      #{offenders.map { |symbol, location| "  #{location}  #{symbol.inspect}" }.join("\n")}
    MESSAGE
  end

  # Without this the guard is green in a vacuum: a regex that quietly stops
  # matching finds no call sites, rejects nothing, and passes.
  it 'actually finds the suite it is supposed to be scanning' do
    symbols = call_sites.map(&:first)

    expect(symbols.size).to be > 50
    expect(symbols).to include(:unprocessable_content)
    expect(symbols).to include(:ok)
  end

  # The expression against every spelling it has to cover, including the two it
  # must NOT match.
  it 'matches the call spellings it claims to' do
    expect('expect(response).to have_http_status(:unprocessable_entity)'[status_symbol, 1]).to eq('unprocessable_entity')
    expect('expect(response).to have_http_status :ok'[status_symbol, 1]).to eq('ok')
    expect('assert_response :not_found'[status_symbol, 1]).to eq('not_found')

    expect('expect(response).to have_http_status(422)').not_to match(status_symbol)
    expect("expect(page).to have_content('unprocessable_entity')").not_to match(status_symbol)
  end

  # The category names have to survive the check -- deleting them from rspec's
  # list would make the first example pass by narrowing what it looks at.
  it 'lets rspec response categories through' do
    expect(generic_statuses).to include(:success, :redirect)
    expect(generic_statuses.any? { |symbol| Rack::Utils::SYMBOL_TO_STATUS_CODE.key?(symbol) }).to be(true)
    expect(Rack::Utils::SYMBOL_TO_STATUS_CODE).not_to have_key(:success)
  end
end
