# frozen_string_literal: true

require 'rails_helper'

# User::ProfileDisplayForm: the form object behind the picture and shown-email form of
# the account's profile tab (Users::RegistrationsController#update_display). The
# end-to-end behaviour is in spec/requests/users/registrations_display_*_spec.rb; this
# holds the form's own rules, the ones a request spec only reaches by accident: what it
# does with something that is no parameters hash, which keys it lets through, and that
# a refused part leaves nothing half saved.
RSpec.describe User::ProfileDisplayForm, type: :model do
  let(:user) { create(:user, email: 'login@example.com') }
  let(:form) { described_class.new(user) }

  def fields(hash)
    ActionController::Parameters.new(hash)
  end

  def png_upload
    Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/test_avatar.png'), 'image/png')
  end

  [nil, 'not-a-hash', 7, [1]].each do |junk|
    it "changes nothing and reports no failure for #{junk.inspect}" do
      expect(form.update(junk)).to be(true)
      expect(user.reload).to have_attributes(email_visibility: 'login', contact_email: nil)
    end
  end

  it 'writes the choice and the address in one save' do
    expect(form.update(fields(email_visibility: 'contact', contact_email: 'team@example.com'))).to be_truthy

    expect(user.reload).to have_attributes(email_visibility: 'contact', contact_email: 'team@example.com')
  end

  it 'lets no other attribute of the account through' do
    form.update(fields(email_visibility: 'none', email: 'other@example.com', first_name: 'Eve',
                       session_timeout_minutes: 1440, language_preference: 'en'))

    expect(user.reload).to have_attributes(email_visibility: 'none', email: 'login@example.com')
    expect(user.first_name).not_to eq('Eve')
    expect(user.session_timeout_minutes).not_to eq(1440)
  end

  it 'reads a blank file field as no change' do
    user.avatar.attach(io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
                       filename: 'existing.png', content_type: 'image/png')
    user.save!

    expect(form.update(fields(avatar: '', email_visibility: 'none'))).to be_truthy

    expect(user.reload.avatar).to be_attached
  end

  it 'saves nothing when one part is refused, and leaves the reason on the user' do
    expect(form.update(fields(avatar: png_upload, email_visibility: 'contact', contact_email: ''))).to be_falsey

    expect(user.errors).to be_present
    expect(User.find(user.id).avatar).not_to be_attached
    expect(User.find(user.id).email_visibility).to eq('login')
  end
end
