# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Style/FormatStringToken -- '%{account_id}' is a stored placeholder that is filled by substitution, not a Ruby format string

# The mail that tells the operator about a new-founder request
# (doc/billing_preisliste_rabatt_plan.md § 12.3.4).
#
# Why the link is a SETTING and not a route (doc/oss_core_split_plan.md 5.2,
# slice S2): the mail is rendered by the core, in the public process. The account
# page it points to belongs to the operator console, an engine that only an
# internal process loads. Once that engine draws the route, admin_account_url
# does not exist where this template renders, and the mail would raise instead
# of going out. So the core knows no console route at all: the operator stores
# an address with a placeholder, and the core only fills in the id.
RSpec.describe FounderSignupMailer do
  let(:founder_signup) { create(:founder_signup) }
  let(:account) { founder_signup.account }

  before { SystemSetting.set(:founder_signup_notification_email, 'ops@example.com') }

  def bodies(mail)
    [mail.html_part.body.decoded, mail.text_part.body.decoded]
  end

  describe '#new_request' do
    it 'goes to the configured address and names the company' do
      mail = described_class.new_request(founder_signup)

      expect(mail.to).to eq(['ops@example.com'])
      expect(mail.subject).to include(founder_signup.company_name)
      bodies(mail).each { |body| expect(body).to include(account.name) }
    end

    it 'links the configured console address with the account id filled in, in both parts' do
      SystemSetting.set(:founder_signup_console_url_template, 'http://localhost:3101/admin/accounts/%{account_id}')

      mail = described_class.new_request(founder_signup)

      bodies(mail).each do |body|
        expect(body).to include("http://localhost:3101/admin/accounts/#{account.id}")
        expect(body).not_to include('%{account_id}')
      end
    end

    # The state of every instance that is not ours, and of ours until the field is
    # filled: the mail still goes out, it just carries no link. Not even a guessed one.
    it 'carries no link at all when no console address is configured' do
      mail = described_class.new_request(founder_signup)

      bodies(mail).each do |body|
        expect(body).not_to include('/admin/accounts')
        expect(body).not_to include(account.id)
      end
      expect(mail.html_part.body.decoded).not_to include(I18n.t('founder_signup_mailer.new_request.cta', locale: :de))
    end

    it 'sends nothing without a recipient' do
      SystemSetting.set(:founder_signup_notification_email, '')

      expect(described_class.new_request(founder_signup).message).to be_a(ActionMailer::Base::NullMail)
    end
  end
end
# rubocop:enable Style/FormatStringToken
