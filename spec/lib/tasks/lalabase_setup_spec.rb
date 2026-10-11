# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `bin/rails lalabase:setup`, the first run of a self-hosted instance.
# Type: Rake task spec.
# Why:  A container entrypoint has no terminal. Without the variables the task must
#       stop with a message, not hang waiting for input nobody can type; and a refusal
#       must end with a failing exit status so the entrypoint notices.
RSpec.describe 'lalabase:setup' do
  let(:password) { 'a' * Setup::CreateFirstAdmin::MINIMUM_PASSWORD_LENGTH }

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('lalabase:setup')
  end

  before { Rake::Task['lalabase:setup'].reenable }

  around do |example|
    keys = %w[LALABASE_ADMIN_EMAIL LALABASE_ADMIN_PASSWORD]
    saved = ENV.to_h.slice(*keys)
    example.run
  ensure
    keys.each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def run_task
    Rake::Task['lalabase:setup'].invoke
  end

  it 'creates the admin from the environment' do
    ENV['LALABASE_ADMIN_EMAIL'] = 'first@example.com'
    ENV['LALABASE_ADMIN_PASSWORD'] = password

    expect { run_task }.to output(/first@example.com created/).to_stdout
    expect(Beuser.find_by(email: 'first@example.com')).to be_active
  end

  it 'stops without a terminal when a value is missing' do
    ENV.delete('LALABASE_ADMIN_EMAIL')
    allow($stdin).to receive(:tty?).and_return(false)

    expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit).not_to be_success }
      .and output(/LALABASE_ADMIN_EMAIL missing/).to_stderr
    expect(Beuser.count).to eq(0)
  end

  it 'fails when an admin exists already' do
    Beuser.create!(email: 'someone@example.com', password: password)
    ENV['LALABASE_ADMIN_EMAIL'] = 'first@example.com'
    ENV['LALABASE_ADMIN_PASSWORD'] = password

    expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit).not_to be_success }
      .and output(/exists already/).to_stderr
  end
end
