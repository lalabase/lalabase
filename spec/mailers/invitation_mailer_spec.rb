# frozen_string_literal: true

require 'rails_helper'

# The invitation mail is the only thing standing between an invited address and
# an account, and it is delivered with deliver_later: nothing in the request
# path notices when it fails. These examples render it for real.
RSpec.describe InvitationMailer, type: :mailer do
  let(:organisation) { create(:organisation, name: 'Acme') }
  let(:inviter)      { create(:user, first_name: 'Wilma', last_name: 'Putzen') }
  let(:invitation) do
    ActsAsTenant.with_tenant(organisation) do
      create(:invitation, organisation: organisation, inviter: inviter,
                          email: 'new.user@example.com', token: 'tok3n4acme')
    end
  end

  let(:mail) { described_class.with(invitation: invitation).invite_email }

  it 'renders instead of raising MissingTemplate' do
    expect { mail.body }.not_to raise_error
  end

  it 'is addressed to the invited address' do
    expect(mail.to).to eq(['new.user@example.com'])
  end

  it 'carries the accept link for this invitation token' do
    expect(mail.body.encoded).to include(
      organisation_accept_invitation_url(organisation_id: organisation.id, token: 'tok3n4acme')
    )
  end

  it 'names the inviter' do
    expect(mail.body.encoded).to include('Wilma').and include('Putzen')
  end

  # The layout already emits <html><body>. A template that emits its own would
  # nest a second document inside the first, which mail clients render badly.
  it 'emits exactly one html document' do
    expect(mail.body.encoded.scan(/<html/i).size).to eq(1)
  end

  %i[de en].each do |locale|
    it "renders subject and body in #{locale} with no missing translations" do
      I18n.with_locale(locale) do
        rendered = described_class.with(invitation: invitation).invite_email
        expect(rendered.subject).to be_present
        expect(rendered.subject).not_to include('translation missing')
        expect(rendered.body.encoded).not_to include('translation missing')
        expect(rendered.body.encoded).not_to include('translation_missing')
      end
    end
  end

  it 'does not sign off with a placeholder app name' do
    expect(mail.body.encoded).not_to match(/DeineApp|YourApp/)
  end
end
