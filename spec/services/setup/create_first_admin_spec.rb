# frozen_string_literal: true

require 'rails_helper'

# The way into /admin of a fresh instance (`bin/rails lalabase:setup`). Pinned: the
# admin it creates can actually sign in (role AND active, the column default of
# active is false), and a second run is refused instead of adding a second door.
RSpec.describe Setup::CreateFirstAdmin do
  let(:password) { 'a' * described_class::MINIMUM_PASSWORD_LENGTH }

  it 'creates an active admin who passes the admin login check' do
    admin = described_class.call(email: ' first@example.com ', password: password)

    expect(admin).to be_persisted
    expect(admin.email).to eq('first@example.com')
    expect(admin.authenticate(password)).to be_truthy
    expect(admin).to be_admin
    expect(admin).to be_active
  end

  it 'refuses once any admin exists' do
    Beuser.create!(email: 'someone@example.com', password: password)

    expect { described_class.call(email: 'first@example.com', password: password) }
      .to raise_error(described_class::Refused, /exists already/)
    expect(Beuser.count).to eq(1)
  end

  it 'refuses a blank email' do
    expect { described_class.call(email: ' ', password: password) }
      .to raise_error(described_class::Refused, /Email/)
  end

  it 'refuses a password one character short of the user minimum' do
    expect { described_class.call(email: 'first@example.com', password: password.chop) }
      .to raise_error(described_class::Refused, /at least #{described_class::MINIMUM_PASSWORD_LENGTH}/)
    expect(Beuser.count).to eq(0)
  end
end
