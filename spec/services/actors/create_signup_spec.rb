# frozen_string_literal: true

require 'rails_helper'

# What: Actors::CreateSignup, the one self-registration shared by the sign-up form and the
#   provisioning endpoint of the separate website (website split, step W2).
# Why: the decisions live here now, not in the controller. Each example breaks at the line
#   that carries its rule: the order of the refusals, all or nothing for user and
#   organisation (owner decision D2), and follow-ups that never undo a signup.
#   The form's HTTP behaviour stays pinned by spec/requests/users/registrations_*_spec.rb.
RSpec.describe Actors::CreateSignup do
  let(:email) { 'ada.signup@example.com' }
  let(:arguments) do
    {
      email: email, password: 'password123', password_confirmation: 'password123',
      first_name: 'Ada', last_name: 'Lovelace', language: 'de', terms_accepted: true
    }
  end
  let(:founder_fields) do
    {
      company_name: 'Neuling Software UG', company_seat: 'Hamburg', founded_on: 6.months.ago.to_date.to_s,
      revenue_band: FounderSignup::REVENUE_BAND_UP_TO_50K, phone: '+49 40 1234567'
    }
  end

  # The seed assigns tutorial tickets as the system account; creating it up front keeps
  # the counts on the registrant.
  before { User.system }

  def signup(**overrides)
    described_class.call(**arguments, **overrides)
  end

  def created_user
    User.find_by(email: email)
  end

  # Users and organisations before and after the block, to prove a refusal wrote nothing.
  def counts_around
    before = [User.count, Organisation.count]
    result = yield
    expect([User.count, Organisation.count]).to eq(before)
    result
  end

  describe 'a signup that is allowed' do
    it 'creates the user, their own organisation with membership and account, and the tutorial' do
      result = signup(organisation_name: 'Lovelace Analytics')

      expect(result).to be_success
      user = result.resource
      expect(user).to be_persisted.and(have_attributes(language_preference: 'de', confirmed_at: nil))
      expect(user.terms_accepted_at).to be_within(1.minute).of(Time.current)
      organisation = ActsAsTenant.without_tenant { user.organisations.sole }
      expect(organisation.name).to eq('Lovelace Analytics')
      expect(ActsAsTenant.without_tenant { organisation.account }).to be_present
      ActsAsTenant.with_tenant(organisation) do
        expect(organisation.projects.where(system_kind: 'onboarding')).to exist
      end
    end

    it 'names the organisation after the address when no name is given' do
      expect(ActsAsTenant.without_tenant { signup.resource.organisations.sole.name }).to eq("Ada.signup's Organisation")
    end

    it 'numbers the organisation name when it is taken' do
      create(:organisation, name: 'Lovelace Analytics')

      organisation = ActsAsTenant.without_tenant { signup(organisation_name: 'Lovelace Analytics').resource.organisations.sole }

      expect(organisation.name).to eq('Lovelace Analytics 2')
    end

    # The mail renders inside the actor's language, not in whatever language the calling
    # thread happens to have (an API request has none). Delivered from a job since
    # 19.09.2026, so this example runs the queue to read what it says.
    it 'sends the confirmation mail once, in the language of the signup' do
      ActionMailer::Base.deliveries.clear

      with_delivered_mails { I18n.with_locale(:de) { signup(language: 'en') } }

      mails = ActionMailer::Base.deliveries.select { |mail| mail.to == [email] }
      expect(mails.size).to eq(1)
      expect(mails.first.subject).to eq(I18n.t('devise.mailer.confirmation_instructions.subject', locale: :en))
    end

    # The messages of a RecordInvalid are rendered by the rescue in
    # with_error_mapping, after the block has returned. With the language nested
    # INSIDE that mapping, an English signup came back with German errors, and
    # only a caller without a request locale of its own ever saw it.
    it 'renders validation errors in the language of the signup, not the thread' do
      result = I18n.with_locale(:de) { signup(language: 'en', email: 'not-an-address') }

      expect(result).not_to be_success
      expect(result.errors).to include(a_string_matching(/is invalid/i))
    end

    # The bug that triggered this: Devise sent the mail inside the request, and a
    # mail server with wrong credentials turned an already committed signup into
    # a 500. The account existed, the customer saw an error, and the second
    # attempt ran into "E-Mail bereits vergeben".
    # Measured on staging through the provisioning endpoint, 19.09.2026.
    it 'creates the account even when the mail server refuses' do
      allow_any_instance_of(Mail::Message).to receive(:deliver)
        .and_raise(Net::SMTPAuthenticationError.new('535 Authentication credentials invalid'))

      result = signup

      expect(result).to be_success
      expect(User.find_by(email: email)).to be_present
    end

    it 'leaves the thread as it found it' do
      I18n.with_locale(:de) do
        signup(language: 'en')

        expect(I18n.locale).to eq(:de)
      end
      expect(Current.user).to be_nil
      expect(ActsAsTenant.current_tenant).to be_nil
    end
  end

  describe 'refusals' do
    {
      'closed registration' => [:registration_closed, -> { allow(SystemSetting).to receive(:allow_registration?).and_return(false) }, {}],
      'terms not accepted' => [:terms_not_accepted, nil, { terms_accepted: false }],
      'a truthy but not true consent' => [:terms_not_accepted, nil, { terms_accepted: '1' }],
      'a throw-away address' => [:disposable_email, nil, { email: 'ada@mailinator.com' }],
      'an incomplete founder request' => [:founder_signup_incomplete, nil, { founder_signup: { company_name: 'Nur ein Name' } }],
      'an unsupported language' => [:invalid_language, nil, { language: 'fr' }]
    }.each do |description, (code, setup, overrides)|
      it "refuses #{description} with #{code} and writes nothing" do
        instance_exec(&setup) if setup

        result = counts_around { signup(**overrides) }

        expect(result).not_to be_success
        expect(result.code).to eq(code)
      end
    end

    # A submission with several problems keeps getting the first message the form always
    # showed first.
    it 'checks consent before the address and the address before the founder request' do
      expect(signup(terms_accepted: false, email: 'ada@mailinator.com').code).to eq(:terms_not_accepted)
      expect(signup(email: 'ada@mailinator.com', founder_signup: { company_name: 'x' }).code).to eq(:disposable_email)
    end

    it 'hands back the unsaved user with its errors when the user is invalid' do
      result = signup(password: 'short', password_confirmation: 'short')

      expect(result.code).to eq(:validation_failed)
      expect(result.resource).not_to be_persisted
      expect(result.resource.errors[:password]).to be_present
    end
  end

  # Owner decision D2 (15.09.2026): until then a failed organisation left a user nobody
  # could repair.
  describe 'all or nothing' do
    it 'rolls back the user, and sends no mail, when the organisation cannot be created' do
      allow(Actors::CreateOrganisation).to receive(:call)
        .and_return(Actors::BaseActor::Result.new(success: false, errors: ['kaputt']))
      mails_before = ActionMailer::Base.deliveries.size

      result = counts_around { signup }

      expect(result.code).to eq(:organisation_creation_failed)
      expect(result.errors).to eq(['kaputt'])
      expect(ActionMailer::Base.deliveries.size).to eq(mails_before)
    end
  end

  describe 'follow-ups after the commit' do
    it 'stores the acquisition source on the new account' do
      stored = { AcquisitionSource::REF => 'linkedin-post', AcquisitionSource::LANDING_PATH => '/de/preise' }

      account = ActsAsTenant.without_tenant { signup(acquisition: stored).resource.organisations.sole.account }

      expect(account.acquisition).to include(AcquisitionSource::REF => 'linkedin-post')
    end

    # The suite does not run on the :test queue adapter globally, so this one example swaps
    # it in and puts it back (same as registrations_founder_signup_spec).
    it 'records the founder request with its marketing consent and mails the operator' do
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      SystemSetting.set(:founder_signup_notification_email, 'ops@example.com')
      signup_actor = described_class.new(**arguments, founder_signup: founder_fields.merge(marketing_consent: true))

      expect { signup_actor.call }.to have_enqueued_mail(FounderSignupMailer, :new_request)

      expect(signup_actor.founder_signup).to be_persisted
      expect(signup_actor.founder_signup.marketing_consent_at).to be_present
    ensure
      ActiveJob::Base.queue_adapter = original_adapter
    end

    it 'records no marketing consent for anything but true' do
      signup_actor = described_class.new(**arguments, founder_signup: founder_fields.merge(marketing_consent: '1'))
      signup_actor.call

      expect(signup_actor.founder_signup).to have_attributes(marketing_consent: false, marketing_consent_at: nil)
    end

    it 'writes the audit entry for the registration' do
      user = signup.resource

      expect(UserActivity.where(user: user, action: UserActivity::ACTIONS[:registered])).to exist
    end

    # Each of these used to be rescued in the controller, and the audit entry not at all
    # (a 500 after everything had committed). None of them may undo the signup now.
    {
      'the onboarding seed' => -> { allow(Actors::SeedOnboarding).to receive(:call).and_raise(StandardError, 'seed') },
      'the acquisition source' => -> { allow(AcquisitionSource).to receive(:from_stored).and_raise(StandardError, 'source') },
      'the founder request' => -> { allow_any_instance_of(FounderSignup).to receive(:save!).and_raise(StandardError, 'founder') },
      'the audit entry' => -> { allow_any_instance_of(User).to receive(:track_registration).and_raise(StandardError, 'audit') }
    }.each do |step, break_it|
      it "keeps the signup when #{step} fails" do
        instance_exec(&break_it)
        signup_actor = described_class.new(**arguments, acquisition: { AcquisitionSource::REF => 'x' },
                                                        founder_signup: founder_fields.merge(marketing_consent: false))

        result = signup_actor.call

        expect(result).to be_success
        expect(created_user).to be_present
        expect(ActsAsTenant.without_tenant { created_user.organisations }).to be_present
      end
    end
  end
end
