# frozen_string_literal: true

require 'rails_helper'

# What: the switch for conversations reads the environment at every call and is on for
#   the value 1 only.
# Why: main ships continuously, and a half-built feature must not show up on an instance
#   that did not ask for it. Ruby treats every set string as true, so a blanked line or
#   a line meant as "off" must not switch it on.
# Nothing asks the switch yet: no route exists that it could close.
RSpec.describe Conversations, :ci_guard do
  let(:flag) { described_class::ENV_FLAG }

  describe '.enabled?' do
    it 'reads the variable LALABASE_CONVERSATIONS' do
      expect(flag).to eq('LALABASE_CONVERSATIONS')
    end

    it 'is on for 1, also with blanks around it' do
      expect(described_class).to be_enabled(flag => '1')
      expect(described_class).to be_enabled(flag => " 1 \n")
    end

    it 'is off without the variable' do
      expect(described_class).not_to be_enabled({})
    end

    ['', ' ', '0', 'true', 'yes', 'on', '2', '11', 'false'].each do |value|
      it "is off for #{value.inspect}" do
        expect(described_class).not_to be_enabled(flag => value)
      end
    end

    it 'is off for the variable of another switch' do
      expect(described_class).not_to be_enabled('LALABASE_DEMO' => '1')
    end

    it 'answers each environment it is asked with, and remembers nothing' do
      expect(described_class.enabled?(flag => '1')).to be(true)
      expect(described_class.enabled?({})).to be(false)
      expect(described_class.enabled?(flag => '1')).to be(true)
    end

    it 'reads the real environment when it is asked without one, at every call' do
      original = ENV.fetch(flag, nil)
      ENV.delete(flag)
      expect(described_class.enabled?).to be(false)

      ENV[flag] = '1'
      expect(described_class.enabled?).to be(true)

      ENV[flag] = '0'
      expect(described_class.enabled?).to be(false)
    ensure
      original.nil? ? ENV.delete(flag) : ENV[flag] = original
    end
  end

  it 'says in its header how it is entered and that nothing asks it yet' do
    header = Rails.root.join('app/services/conversations.rb').read.lines.take_while { |line| !line.start_with?('module ') }.join

    expect(header).to match(/^# Entry point: enabled\?$/)
    expect(header).to include('Nothing asks the switch yet')
  end

  it 'has no caller in the application' do
    callers = Dir[Rails.root.join('{app,lib,config}/**/*.{rb,erb,rake}')].select do |path|
      File.read(path).match?(/\bConversations\.enabled\?/)
    end

    expect(callers).to be_empty
  end
end
