# frozen_string_literal: true

require 'rails_helper'

# Enforces the retention promise of privacy policy § 4.1
# (doc/billing_preisliste_rabatt_plan.md § 12.3.4).
RSpec.describe FounderSignupCallbackNumberCleanupJob do
  def signup(**attrs)
    create(:founder_signup, account: create(:account), **attrs)
  end

  it 'drops the number once the request is decided' do
    request = signup(status: FounderSignup::STATUS_GRANTED, decided_at: 1.day.ago)

    described_class.perform_now

    expect(request.reload.phone).to be_nil
  end

  it 'drops it for a declined request too' do
    request = signup(status: FounderSignup::STATUS_DECLINED, decided_at: 1.day.ago)

    described_class.perform_now

    expect(request.reload.phone).to be_nil
  end

  # The "at the latest" half of the promise. Without it a request nobody ever
  # decides keeps its number forever — the failure a retention rule exists for.
  it 'drops it from an undecided request past the retention window' do
    request = signup(created_at: (FounderSignup::CALLBACK_NUMBER_RETENTION + 1.day).ago)

    described_class.perform_now

    expect(request.reload.phone).to be_nil
  end

  it 'keeps it while the request is open and inside the window' do
    request = signup(created_at: 2.days.ago)

    described_class.perform_now

    expect(request.reload.phone).to be_present
  end

  # Consent to sales contact is a SEPARATE purpose (Art. 6 (1) a) and ends with
  # the withdrawal, not with this decision.
  it 'keeps it when consent to sales contact was given' do
    request = signup(status: FounderSignup::STATUS_GRANTED, decided_at: 1.day.ago,
                     marketing_consent: true, marketing_consent_at: 1.day.ago)

    described_class.perform_now

    expect(request.reload.phone).to be_present
  end

  # Only the number. Everything else is either duplicated by accounts.name under
  # the contract or is what the request exists to be evaluated on.
  it 'touches nothing but the number' do
    request = signup(status: FounderSignup::STATUS_GRANTED, decided_at: 1.day.ago)
    before = request.slice(:company_name, :company_seat, :founded_on, :revenue_band, :status)

    described_class.perform_now

    expect(request.reload.slice(:company_name, :company_seat, :founded_on, :revenue_band, :status)).to eq(before)
  end

  it 'is idempotent' do
    signup(status: FounderSignup::STATUS_GRANTED, decided_at: 1.day.ago)

    described_class.perform_now
    expect { described_class.perform_now }.not_to raise_error
  end
end
