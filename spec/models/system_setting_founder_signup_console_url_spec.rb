# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Style/FormatStringToken -- '%{account_id}' is a stored placeholder that is filled by substitution, not a Ruby format string

# The address of the operator console in the founder mail, as a template with
# one placeholder (doc/oss_core_split_plan.md 5.2). The rule lives in the core
# model, because two callers need it: the console when it stores the value, and
# the core mailer when it reads it.
RSpec.describe SystemSetting do
  let(:account) { create(:account) }

  describe '.valid_founder_signup_console_url_template?' do
    it 'accepts nothing, which means "no link"' do
      expect(described_class.valid_founder_signup_console_url_template?('')).to be(true)
      expect(described_class.valid_founder_signup_console_url_template?(nil)).to be(true)
    end

    it 'accepts an absolute http(s) address that carries the placeholder' do
      %w[http://localhost:3101/admin/accounts/%{account_id}
         https://console.example.com/admin/accounts/%{account_id}?tab=founder].each do |template|
        expect(described_class.valid_founder_signup_console_url_template?(template)).to be(true), template
      end
    end

    # A mail client runs a javascript: link on click, and a relative path has no
    # host in a mail. Without the placeholder every mail would link the same page.
    it 'refuses everything else' do
      ['/admin/accounts/%{account_id}', 'javascript:alert(1)//%{account_id}', 'localhost:3101/%{account_id}',
       'http://localhost:3101/admin/accounts', 'http://localhost:3101/%{id}', 'not a url %{account_id}'].each do |template|
        expect(described_class.valid_founder_signup_console_url_template?(template)).to be(false), template
      end
    end
  end

  describe '.founder_signup_console_url' do
    it 'is nil while nothing is configured' do
      expect(described_class.founder_signup_console_url(account)).to be_nil
    end

    it 'fills the account id into the template' do
      described_class.set(:founder_signup_console_url_template, 'http://localhost:3101/admin/accounts/%{account_id}')

      expect(described_class.founder_signup_console_url(account)).to eq("http://localhost:3101/admin/accounts/#{account.id}")
    end

    # Filled in by substitution, not by Kernel#format: a stored value with a
    # second, unknown placeholder would make format raise KeyError, in a mailer
    # job, for a value someone typed weeks earlier.
    it 'does not raise on a stray percent sign or placeholder in a stored value' do
      described_class.set(:founder_signup_console_url_template, 'http://localhost/%{other}/100%/%{account_id}')

      expect(described_class.founder_signup_console_url(account)).to eq("http://localhost/%{other}/100%/#{account.id}")
    end
  end
end
# rubocop:enable Style/FormatStringToken
