# frozen_string_literal: true

require 'rails_helper'

# The ARM workaround is worth exactly as much as its weakest registration.
#
# selenium-webdriver ships a single x86-64 binary for Linux, so on an aarch64
# machine Selenium Manager cannot run at all (see the long note in
# spec/support/capybara.rb). LocalChrome routes around it, but only for drivers
# that actually go through it, and there are FOUR Chrome registrations spread
# over two files -- three in spec/support/capybara.rb, one more in
# rails_helper.rb that silently re-registers a name the support file already
# used.
#
# A fifth one that forgets `LocalChrome.apply_binary` would not fail here or in
# CI: system specs do not run in guards.yml. It would fail on somebody's machine,
# with the shell-syntax-error message that names neither Chrome nor the
# architecture. So the rule gets checked instead of written into a comment.
RSpec.describe 'Chrome driver registrations', type: :model do
  let(:guard_itself) { 'spec/architecture/chrome_driver_binary_guard_spec.rb' }

  # Both files that build Capybara Selenium drivers today. A new file would need
  # adding here -- deliberate: this list is short enough to stay honest, and
  # scanning all of spec/ would drag in every fixture that mentions the class.
  let(:driver_files) { %w[spec/support/capybara.rb spec/rails_helper.rb] }

  # Text from each `Capybara::Selenium::Driver.new` up to the next blank line is
  # enough to cover a call written on one line or across five.
  def driver_calls(relative_path)
    body = Rails.root.join(relative_path).read
    body.split('Capybara::Selenium::Driver.new')[1..].to_a.map { |tail| tail.split("\n\n").first.to_s }
  end

  it 'routes every Chrome driver through LocalChrome.apply_binary' do
    offenders = driver_files.flat_map do |relative_path|
      driver_calls(relative_path).each_with_index.filter_map do |call, index|
        "#{relative_path} (call ##{index + 1})" unless call.include?('LocalChrome.apply_binary')
      end
    end

    expect(offenders).to be_empty, <<~MESSAGE
      These Capybara Selenium drivers bypass LocalChrome.apply_binary, so they
      fall back to Selenium Manager -- which has no ARM64 Linux binary and dies
      with `1: Syntax error: "(" unexpected`.

      Wrap the options: `options: LocalChrome.apply_binary(options)`.

      #{offenders.map { |offender| "  #{offender}" }.join("\n")}
    MESSAGE
  end

  # Without this the guard passes on an empty scan: rename the class, find no
  # calls, reject nothing, stay green.
  it 'actually finds the registrations it is scanning' do
    counts = driver_files.index_with { |relative_path| driver_calls(relative_path).size }

    expect(counts['spec/support/capybara.rb']).to eq(3)
    expect(counts['spec/rails_helper.rb']).to eq(1)
  end

  # The owner has to keep existing, and keep deciding nothing on a machine where
  # Selenium Manager works. Setting a path unconditionally would break macOS.
  it 'leaves Selenium Manager alone when no local chromedriver is present' do
    expect(LocalChrome).to respond_to(:apply_binary, :driver_path, :browser_binary)
    expect(LocalChrome.executable?(nil)).to be(false)
    expect(LocalChrome.executable?('/definitely/not/here/chromedriver')).to be(false)
    expect(LocalChrome.executable?('/bin/sh')).to be(true)
  end
end
