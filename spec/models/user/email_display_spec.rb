# frozen_string_literal: true

require 'rails_helper'

# Which email the others see (User::EmailDisplay). The member chooses it in the
# display preferences: the login address (default), a contact address, or none.
RSpec.describe User::EmailDisplay, :ci_guard, type: :model do
  let(:user) { create(:user, email: 'login@example.com') }

  describe 'the choice' do
    it 'starts at the login address when nothing was chosen' do
      fresh = User.create!(email: 'fresh@example.com', password: 'password123', first_name: 'Frida', last_name: 'Frisch')

      expect(fresh.reload).to have_attributes(email_visibility: 'login', contact_email: nil)
    end

    User::EmailDisplay::EMAIL_VISIBILITIES.each do |visibility|
      it "accepts #{visibility}" do
        user.assign_attributes(email_visibility: visibility, contact_email: 'team@example.com')

        expect(user).to be_valid
      end
    end

    it 'knows exactly three choices' do
      expect(User::EmailDisplay::EMAIL_VISIBILITIES).to eq(%w[login contact none])
    end

    %w[public Login hidden].push('').each do |bad|
      it "refuses #{bad.inspect}" do
        user.email_visibility = bad

        expect(user).not_to be_valid
        expect(user.errors.details[:email_visibility]).to include(a_hash_including(error: :inclusion))
      end
    end

    it 'refuses the contact choice without an address' do
      user.assign_attributes(email_visibility: 'contact', contact_email: '  ')

      expect(user).not_to be_valid
      expect(user.errors.details[:contact_email]).to include(a_hash_including(error: :blank))
    end
  end

  describe 'the contact address' do
    %w[team@example.com e.beispiel+kontakt@sub.example.com].each do |good|
      it "accepts #{good}" do
        user.contact_email = good

        expect(user).to be_valid
      end
    end

    ['team@', '@example.com', 'team example.com'].each do |bad|
      it "refuses #{bad.inspect}" do
        user.contact_email = bad

        expect(user).not_to be_valid
        expect(user.errors.details[:contact_email]).to include(a_hash_including(error: :invalid))
      end
    end

    it 'stores a blank address as nil' do
      user.update!(contact_email: '   ')

      expect(user.reload.contact_email).to be_nil
    end

    it 'strips the address' do
      user.update!(contact_email: ' team@example.com ')

      expect(user.reload.contact_email).to eq('team@example.com')
    end

    it 'accepts an address at the limit and refuses one character more' do
      # Domain labels stay at 63 characters or fewer, so the format accepts
      # both addresses and only the length decides.
      local = 'a' * 64
      at_limit = "#{local}@#{'b' * 61}.#{'c' * 61}.#{'d' * 62}.com"
      expect(at_limit.length).to eq(User::EmailDisplay::MAX_CONTACT_EMAIL_LENGTH)

      user.contact_email = at_limit
      expect(user).to be_valid

      user.contact_email = "#{local}@#{'b' * 62}.#{'c' * 61}.#{'d' * 62}.com"
      expect(user).not_to be_valid
      expect(user.errors.details[:contact_email]).to include(a_hash_including(error: :too_long))
    end

    it 'keeps the address when the member switches back to the login address or to none' do
      user.update!(email_visibility: 'contact', contact_email: 'team@example.com')
      user.update!(email_visibility: 'none')

      expect(user.reload.contact_email).to eq('team@example.com')
    end
  end

  describe '#shown_email' do
    it 'is the login address by default' do
      expect(user.shown_email).to eq('login@example.com')
    end

    it 'is the contact address when the member chose it' do
      user.update!(email_visibility: 'contact', contact_email: 'team@example.com')

      expect(user.shown_email).to eq('team@example.com')
    end

    it 'is nil when the member chose none, also with a stored contact address' do
      user.update!(email_visibility: 'none', contact_email: 'team@example.com')

      expect(user.shown_email).to be_nil
    end

    it 'is the login address for login, even with a stored contact address' do
      user.update!(email_visibility: 'login', contact_email: 'team@example.com')

      expect(user.shown_email).to eq('login@example.com')
    end
  end

  describe '.matching_shown_email' do
    let!(:plain) { create(:user, email: 'plain@example.com') }
    let!(:contact) { create(:user, email: 'secret-login@example.com', email_visibility: 'contact', contact_email: 'shown@example.com') }
    let!(:hidden) do
      create(:user, email: 'hidden-login@example.com', email_visibility: 'none', contact_email: 'kept-contact@example.com')
    end
    let!(:back_to_login) do
      create(:user, email: 'back-login@example.com', email_visibility: 'login', contact_email: 'old-contact@example.com')
    end

    it 'finds the login address of a member who shows it' do
      expect(User.matching_shown_email('plain@')).to contain_exactly(plain)
    end

    it 'finds the contact address, case-insensitive' do
      expect(User.matching_shown_email('SHOWN@')).to contain_exactly(contact)
    end

    # A stored contact address stays when the member switches away from it; it
    # is not shown then, so it must not be found either.
    it 'never finds a stored contact address the member does not show' do
      expect(User.matching_shown_email('kept-contact')).to be_empty
      expect(User.matching_shown_email('old-contact')).to be_empty
      expect(User.matching_shown_email('back-login')).to contain_exactly(back_to_login)
    end

    it 'never finds a hidden login address' do
      expect(User.matching_shown_email('secret-login')).to be_empty
      expect(User.matching_shown_email('hidden-login')).to be_empty
    end

    it 'treats LIKE wildcards as text' do
      expect(User.matching_shown_email('%')).to be_empty
      expect(User.matching_shown_email('_')).to be_empty
    end
  end

  describe 'the database behind the model' do
    it 'refuses an unknown choice past the validation' do
      user.email_visibility = 'public'

      expect { user.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid, /users_email_visibility_known/)
    end

    it 'refuses a missing choice past the validation' do
      expect { user.update_column(:email_visibility, nil) }.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe 'the name when there is none' do
    let(:nameless) { create(:user, email: 'secret-login@example.com', first_name: nil, last_name: nil) }

    it 'takes the part before the @ of the login address while the member shows it' do
      expect(nameless.display_name).to eq('secret-login')
    end

    it 'takes the part before the @ of the contact address when the member chose it' do
      nameless.update!(email_visibility: 'contact', contact_email: 'team@example.com')

      expect(nameless.display_name).to eq('team')
    end

    it 'never takes the login address when the member hides it' do
      nameless.update!(email_visibility: 'none')

      expect(nameless.display_name).not_to include('secret')
      expect(nameless.display_name).to eq(I18n.t('users.unnamed'))
      expect(nameless.initials).not_to start_with('S')
    end
  end
end
