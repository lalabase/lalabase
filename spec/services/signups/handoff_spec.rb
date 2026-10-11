# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Signups::Handoff do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }

  around do |example|
    previous = Rails.configuration.x.provisioning
    Rails.configuration.x.provisioning = Lalabase::ProvisioningConfiguration.new(secret: SecureRandom.hex(32))
    example.run
  ensure
    Rails.configuration.x.provisioning = previous
  end

  def token_for(person)
    described_class.url_for(user: person)[/token=([^&]+)/, 1]
  end

  describe '.url_for' do
    it 'points at the core address the confirmation mail uses' do
      expect(described_class.url_for(user: user))
        .to start_with("http://#{ActionMailer::Base.default_url_options.fetch(:host)}/users/signup_handoff?token=")
    end

    # The suite sets a host on the ROUTES, so a url_for that reads no host of its
    # own still produces a URL here and would take the wrong one to production.
    it 'carries the mailer host even when the routes know none' do
      previous = Rails.application.routes.default_url_options.delete(:host)

      expect(described_class.url_for(user: user)).to include(ActionMailer::Base.default_url_options.fetch(:host))
    ensure
      Rails.application.routes.default_url_options[:host] = previous
    end
  end

  describe '.claim' do
    it 'answers the user for a fresh link' do
      expect(described_class.claim(token: token_for(user))).to eq(user)
    end

    # The whole point of the claim: the link is a one-way door, and two clicks
    # arriving together cannot both walk through it.
    it 'answers only the first caller, even for the same token' do
      token = token_for(user)

      expect(described_class.claim(token: token)).to eq(user)
      expect(described_class.claim(token: token)).to be_nil
    end

    it 'refuses an account that has been seen before, however fresh the link' do
      user.update_column(:last_seen_at, 1.minute.ago)

      expect(described_class.claim(token: token_for(user))).to be_nil
    end

    it 'expires' do
      token = token_for(user)

      travel_to(described_class::VALID_FOR.from_now + 1.second) do
        expect(described_class.claim(token: token)).to be_nil
      end
    end

    # Without the purpose, any signed id of this user would open a session.
    it 'refuses a signed id minted for something else' do
      expect(described_class.claim(token: user.signed_id(purpose: :something_else))).to be_nil
    end

    it 'refuses a made-up or empty token' do
      expect(described_class.claim(token: 'not-a-token')).to be_nil
      expect(described_class.claim(token: nil)).to be_nil
    end

    it 'refuses an account that may not sign in at all' do
      expired = create(:user, :confirmation_overdue)

      expect(described_class.claim(token: token_for(expired))).to be_nil
      expect(expired.reload.last_seen_at).to be_nil
    end

    # Defence in depth: an instance that does not run a separate website has no
    # use for a link that opens sessions, even one that was minted earlier.
    it 'refuses while provisioning is switched off' do
      token = token_for(user)
      Rails.configuration.x.provisioning = Lalabase::ProvisioningConfiguration.new

      expect(described_class.claim(token: token)).to be_nil
    end
  end
end
