# frozen_string_literal: true

require 'rails_helper'

# What: code that shows or searches a member's email for OTHER people reads it
#   through User#shown_email (User::EmailDisplay), never through a bare `.email`.
# Why: a member chooses which email the others see (the login address, a contact
#   address, or none). Until 29.10.2026 every place read the login address
#   directly: the people directory, the assistant/MCP/REST card, the members page
#   (for every member, customers included), smart folder sharing, the subscriber
#   picker, the activity page and the import preview. A choice that each of
#   those has to remember is not a choice, so the bare read is refused here.
#
# A tripwire, not a proof: it reads `<receiver>.email` / `<receiver>&.email` in
# Ruby, ERB and JavaScript. It does not see an email reached through `send`,
# `[:email]`, `pluck(:email)`, `as_json` of a whole user, or a SQL fragment.
module ShownEmailGuard
  ROOTS = %w[app/controllers app/services app/views app/helpers app/components app/javascript].freeze

  # The account owner's own view, Lalabase's own mail, Devise and the instance
  # admin area keep the login address on purpose (User::EmailDisplay header).
  EXCLUDED = %r{\Aapp/(?:views|controllers|services)/admin/|\Aapp/views/devise/|\Aapp/controllers/users/|
                mailers?/|_mailer|\Aapp/views/user_data_exports/|\Aapp/services/user_data_exports/}x

  # Receivers whose `.email` is not a member's login address shown to others.
  SAFE_RECEIVERS = {
    'person' => 'a person row of the directory (a contact typed by colleagues), not an account',
    'invitation' => 'the address an invitation was sent to, shown to the inviter before any account exists',
    'current_user' => "the viewer's own account",
    'placeholders' => 'part of an i18n key (views.organisations.people.form.placeholders.email)'
  }.freeze

  # Shrink-only: [file, receiver] and why that read is not a member's address shown
  # to others. An entry without a finding left fails as well.
  ALLOWED = {
    ['app/controllers/api/v1/me_controller.rb', 'user'] =>
      "GET /api/v1/me answers the token holder's own account",
    ['app/services/codebase_import/user_matcher.rb', 'u'] =>
      'the exact match of an import finds the account by its login address; the preview shows the shown email',
    ['app/services/codebase_import/ticket_update_importer.rb', 'new_assignee'] =>
      'a debug log line on the server, never rendered',
    ['app/controllers/organisations/documents_controller.rb', 'users'] =>
      'a whitelisted SQL sort column name, not a value shown to anyone',
    ['app/services/notifications/score_calculator.rb', '@recipient'] =>
      "compares the recipient's own address with a rule value, nothing is shown",
    ['app/javascript/controllers/subscriber_picker_controller.js', 'user'] =>
      'reads the JSON field `email`, which the server fills with User#shown_email'
  }.freeze

  CALL = /(?<receiver>@?[A-Za-z_]\w*)(?:\.|&\.)email\b(?![\w?!=])/

  def self.files
    ROOTS.flat_map { |root| Dir[Rails.root.join(root, '**', '*.{rb,erb,js}')] }
         .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }
         .reject { |path| path.match?(EXCLUDED) }
         .sort
  end

  # [[file, receiver, line number, text]] of every bare read
  def self.findings
    files.flat_map do |file|
      File.readlines(Rails.root.join(file)).each_with_index.flat_map do |line, index|
        next [] if line.match?(%r{\A\s*(?:#|<%#|//)})

        line.to_enum(:scan, CALL).map { Regexp.last_match[:receiver] }
            .reject { |receiver| SAFE_RECEIVERS.key?(receiver.delete_prefix('@')) }
            .map { |receiver| [file, receiver, index + 1, line.strip] }
      end
    end
  end
end

RSpec.describe ShownEmailGuard, :ci_guard do
  it 'finds every bare member email outside the shown email' do
    unexpected = described_class.findings.reject { |file, receiver, *| described_class::ALLOWED.key?([file, receiver]) }

    expect(unexpected).to be_empty, lambda {
      lines = unexpected.map { |file, _receiver, line, text| "  #{file}:#{line}: #{text}" }.join("\n")
      "A member's email shown to others goes through User#shown_email, not `.email`:\n#{lines}"
    }
  end

  it 'keeps no allow-list entry without a finding' do
    found = described_class.findings.to_set { |file, receiver, *| [file, receiver] }
    stale = described_class::ALLOWED.keys.reject { |key| found.include?(key) }

    expect(stale).to be_empty, "Remove the stale entries: #{stale.inspect}"
  end

  it 'reads the places it promises to read' do
    files = described_class.files

    expect(files).to include('app/views/organisations/memberships/_member.html.erb',
                             'app/services/people/directory.rb', 'app/services/people/lookup.rb',
                             'app/javascript/controllers/subscriber_picker_controller.js')
    expect(files).not_to include('app/views/devise/registrations/edit.html.erb')
  end

  it 'sees a bare read in Ruby, ERB and JavaScript, and lets the shown email pass' do
    probe = ->(text) { text.to_enum(:scan, described_class::CALL).map { Regexp.last_match[:receiver] } }

    expect(probe.call('<%= membership.user.email %>')).to eq(['user'])
    expect(probe.call('entry.user&.email')).to eq(['user'])
    expect(probe.call('${member.email}')).to eq(['member'])
    expect(probe.call('membership.user.shown_email')).to eq([])
    expect(probe.call('user.email_visibility')).to eq([])
    expect(probe.call('user.email?')).to eq([])
  end
end
