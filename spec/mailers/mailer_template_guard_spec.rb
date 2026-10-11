# frozen_string_literal: true

require 'rails_helper'

# Every mailer action must have a template Rails can actually find.
#
# Why this guard exists: InvitationMailer#invite_email had no reachable template
# for 16 months. Commit 8b72f207 ("ordnerstruktur") moved the view folder to
# app/views/organisations/invitation_mailer/ and renamed the controller to
# Organisations::InvitationsController, but left the mailer class unnamespaced.
# Rails kept looking in app/views/invitation_mailer/, found nothing, and raised
# ActionView::MissingTemplate. Because the only caller uses deliver_later, the
# raise happened inside ActionMailer::MailDeliveryJob: the request succeeded,
# the flash said "invitation sent", and no invitation email was ever delivered.
#
# A missing mailer template is invisible until somebody reads a failed job, so
# the rule cannot live in review discipline. It lives here.
RSpec.describe 'Mailer template reachability', type: :mailer do
  # Mailer actions that legitimately render no template of their own.
  # Empty on purpose: an entry here needs a reason, not just a green run.
  let(:templateless_actions) { [] }

  let(:mailer_root) { Rails.root.join('app/mailers') }

  let(:mailer_classes) do
    constants = Dir[mailer_root.join('**/*.rb')].map do |path|
      Pathname.new(path).relative_path_from(mailer_root).sub_ext('').to_s.camelize.constantize
    end
    constants.select { |klass| klass < ActionMailer::Base }
  end

  it 'finds mailers to check' do
    expect(mailer_classes).not_to be_empty
  end

  it 'resolves a template for every mailer action' do
    missing = mailer_classes.flat_map do |klass|
      lookup = klass.new.lookup_context
      actions = klass.action_methods.reject { |action| templateless_actions.include?("#{klass}##{action}") }
      actions.reject { |action| lookup.exists?(action, klass._prefixes, false) }
             .map { |action| "#{klass}##{action} (searched: #{klass._prefixes.join(', ')})" }
    end

    expect(missing).to be_empty,
                       "Mailer actions with no reachable template:\n  #{missing.join("\n  ")}\n\n" \
                       'Rails looks under app/views/<mailer_name_underscored>/. A mailer that lives ' \
                       'in a namespace needs its views in the matching namespace, and vice versa.'
  end
end
