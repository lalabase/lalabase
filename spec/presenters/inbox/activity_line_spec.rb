# frozen_string_literal: true

require 'rails_helper'

# The actor of an inbox line is named like everywhere else (User#display_name):
# a member without a name never appears with the login address they hide
# (User::EmailDisplay).
RSpec.describe Inbox::ActivityLine, :ci_guard do
  def line_for(actor)
    described_class.new(instance_double(Notification, actor: actor))
  end

  it 'names the actor by name' do
    expect(line_for(build(:user, first_name: 'Nina', last_name: 'Beispiel')).actor_name).to eq('Nina Beispiel')
  end

  it 'never names a nameless actor by a hidden login address' do
    ghost = build(:user, first_name: nil, last_name: nil, email: 'ghost-login@example.com', email_visibility: 'none')

    expect(line_for(ghost).actor_name).to eq(I18n.t('users.unnamed'))
  end

  it 'names a nameless actor who shows a contact address by that address' do
    ghost = build(:user, first_name: nil, last_name: nil, email: 'ghost-login@example.com',
                         email_visibility: 'contact', contact_email: 'ghost.team@example.com')

    expect(line_for(ghost).actor_name).to eq('ghost.team')
  end
end
