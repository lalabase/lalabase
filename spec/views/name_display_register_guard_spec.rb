# frozen_string_literal: true

require 'rails_helper'

# Guard: no raw user full_name renders outside the name-display register.
#
# The viewer's name-display setting (Settings > Profil) only works if
# every surface goes through one of the three seams:
#   - Neo::Users::NameComponent      -> a user as an identity LABEL
#   - viewer_user_list(users)        -> a GROUP of users (pair when one, chips when several)
#   - viewer_display_name(user)      -> a name inside prose
# A raw `.full_name` in a view or component silently opts that surface out of
# the setting — exactly the drift behind the two post-deploy reports of
# 04.09.2026 ("the circle does nothing here").
#
# The register (which surface renders what, and WHY the exceptions are
# exceptions) lives in docs/dokumentation/namensanzeige_flaechenregister.md;
# this spec is its enforcement. A new deliberate exception means: entry in
# ALLOWED_RAW_FULL_NAME below WITH a reason, plus a line in the register.

# path (or directory prefix ending in /) => reason
NAME_DISPLAY_ALLOWED_RAW_FULL_NAME = {
  # Mailers render without a viewer — there is no preference to apply.
  'app/views/notification_mailer/' => 'Mailer: kein Betrachter, immer voller Name',
  # The admin backend keeps its own styleguide and the email-fallback
  # full_name (pinned by spec/models/admin/user_spec.rb).
  'app/views/admin/' => 'Adminbereich: eigener Styleguide',
  # Only turbo_confirm texts and hover titles — full precision before a
  # destructive/adding click; the visible labels go through user_label.
  'app/components/neo/subscriber_list_component.html.erb' =>
    'Bestaetigungsdialoge und Hover-Titel tragen bewusst den vollen Namen',
  # data-name feeds the member-picker substring search, not the display.
  'app/views/organisations/project_permissions/index.html.erb' =>
    'data-name-Filterattribut: Suche matcht auf den vollen Namen',
  # The same rule as the subscriber list: only the turbo_confirm before removing a
  # member names them in full; the visible labels go through viewer_display_name.
  'app/views/organisations/memberships/_member.html.erb' =>
    'Bestaetigungsdialog vor dem Entfernen traegt bewusst den vollen Namen',
  'app/views/organisations/memberships/_panel.html.erb' =>
    'Bestaetigungsdialog vor dem Entfernen traegt bewusst den vollen Namen'
}.freeze

# Repository#full_name (the GitHub "owner/repo" string) and form-field
# symbols share the method name but have nothing to do with user names.
NAME_DISPLAY_NON_USER_FULL_NAME = /repo\.full_name|repository\.full_name|:full_name|full_name_label|full_name_hint/

RSpec.describe 'Name display register guard' do
  def offending_files
    files = Dir[Rails.root.join('app/views/**/*.erb'), Rails.root.join('app/components/**/*.{rb,erb}')]
    offenders = files.select do |file|
      File.readlines(file).any? do |line|
        line.match?(/\.full_name\b/) && !line.match?(NAME_DISPLAY_NON_USER_FULL_NAME) &&
          !line.strip.start_with?('#', '<%#')
      end
    end
    offenders.map { |f| Pathname.new(f).relative_path_from(Rails.root).to_s }.sort
  end

  def allowed?(path)
    NAME_DISPLAY_ALLOWED_RAW_FULL_NAME.keys.any? do |entry|
      entry.end_with?('/') ? path.start_with?(entry) : path == entry
    end
  end

  it 'every raw full_name render site is a registered exception' do
    unexpected = offending_files.reject { |path| allowed?(path) }

    expect(unexpected).to be_empty, <<~MSG
      Rohes `.full_name` ausserhalb des Namensanzeige-Registers gefunden:

      #{unexpected.map { |f| "  - #{f}" }.join("\n")}

      Diese Flaeche folgt damit NICHT der Namensanzeige-Einstellung. Bitte
      einen der drei Seams benutzen (Neo::Users::NameComponent /
      viewer_user_list / viewer_display_name) ODER die Ausnahme MIT Grund
      in NAME_DISPLAY_ALLOWED_RAW_FULL_NAME eintragen und im Register
      nachziehen: docs/dokumentation/namensanzeige_flaechenregister.md
    MSG
  end

  it 'the allowlist carries no stale entries (shrink-only)' do
    offenders = offending_files
    stale = NAME_DISPLAY_ALLOWED_RAW_FULL_NAME.keys.reject do |entry|
      if entry.end_with?('/')
        offenders.any? { |path| path.start_with?(entry) }
      else
        offenders.include?(entry)
      end
    end

    expect(stale).to be_empty, <<~MSG
      Allowlist-Eintraege ohne verbleibende Fundstelle (bitte entfernen,
      sonst deckt die Liste irgendwann etwas Ungeprueftes):

      #{stale.map { |e| "  - #{e}" }.join("\n")}
    MSG
  end
end
