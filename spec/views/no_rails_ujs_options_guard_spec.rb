# frozen_string_literal: true

require 'rails_helper'

# Guard: no leftover rails-ujs options in views or components.
#
# rails-ujs is NOT loaded in this app — see config/importmap.rb
# ("pin '@rails/ujs' ... # Not used with Turbo") and the commented-out import
# in app/javascript/application.js. Turbo is the only driver.
#
# That makes two long-standing Rails idioms silently dead here:
#
#   1. `link_to path, method: :delete`
#      Without UJS nothing rewrites the anchor, so the browser issues a plain
#      GET. Depending on the route that is either a RoutingError (POST/PATCH-only
#      endpoints) or — worse — a silent no-op that navigates somewhere harmless
#      (a DELETE path also answering GET #show). Turbo equivalent:
#      `data: { turbo_method: :delete }`.
#
#   2. `data: { confirm: '...' }`
#      UJS read `data-confirm`; Turbo reads `data-turbo-confirm`. Without the
#      turbo_ prefix the confirmation dialog never appears and destructive
#      actions fire on the first click. Turbo equivalent:
#      `data: { turbo_confirm: '...' }`.
#
# Both were found dead across the admin area in 07/2026 (see
# docs/letzte_arbeiten/2026_07_30_1_letzte_arbeiten_admin_turbo_method_links.md).
#
# Note the deliberate absence of an allowlist: every offender was fixed rather
# than grandfathered, so this guard starts at zero. If a genuine exception ever
# appears, add an allowlist here AND explain why UJS semantics are needed in an
# app that does not ship UJS.
RSpec.describe 'rails-ujs leftovers guard' do
  # Matches a full `<%= link_to ... %>` / `<%= button_to ... %>` ERB tag,
  # including the `do %>` opener of the block form.
  let(:erb_link_tag) { /<%=?\s*(?:link_to|button_to)\b.*?%>/m }

  # `method: :delete` but NOT `turbo_method: :delete`.
  let(:ujs_method_option) { /(?<!turbo_)\bmethod:\s*:(?:post|patch|put|delete)\b/ }

  # `confirm:` inside a `data:` hash, but NOT `turbo_confirm:`.
  # Scoped to the data hash on purpose: ViewComponents (Neo::Buttons::*) take a
  # top-level `confirm:` kwarg and map it to turbo_confirm themselves — that one
  # is correct and must not be flagged.
  let(:ujs_data_confirm) { /data:\s*\{[^}]*(?<!turbo_)\bconfirm:/m }

  let(:scanned_files) do
    %w[app/views/**/*.erb app/components/**/*.erb]
      .flat_map { |glob| Dir[Rails.root.join(glob)] }
      .sort
  end

  # Returns "relative/path.erb:LINE" for every link_to tag whose option list
  # matches `pattern`. button_to is excluded on purpose: there `method:` is the
  # documented Rails API and renders a real form, so it is correct.
  def link_to_offenders(files, pattern)
    files.flat_map do |file|
      source = File.read(file)
      relative = Pathname.new(file).relative_path_from(Rails.root).to_s

      source.to_enum(:scan, erb_link_tag).filter_map do
        match = Regexp.last_match
        next unless match[0].match?(/<%=?\s*link_to\b/)
        next unless match[0].match?(pattern)

        "#{relative}:#{source[0...match.begin(0)].count("\n") + 1}"
      end
    end
  end

  it 'kein link_to nutzt die rails-ujs-Option method:' do
    offenders = link_to_offenders(scanned_files, ujs_method_option)

    expect(offenders).to be_empty, <<~MSG
      link_to mit rails-ujs-Option `method:` gefunden:

      #{offenders.map { |o| "  - #{o}" }.join("\n")}

      rails-ujs ist in dieser App nicht geladen (config/importmap.rb) — der Link
      feuert damit ein stilles GET. Bitte auf `data: { turbo_method: :verb }`
      umstellen (oder auf button_to, wenn die Aktion ohne JS funktionieren soll).
    MSG
  end

  # Deliberately NOT scoped to link_to/button_to: the worst offender found in
  # 07/2026 was a `form.submit` ("Konto loeschen" fired with no dialog at all).
  # Any helper can carry a data hash, so scan the whole file.
  it 'nirgends wird die rails-ujs-Option data: { confirm: } verwendet' do
    offenders = scanned_files.flat_map do |file|
      source = File.read(file)
      relative = Pathname.new(file).relative_path_from(Rails.root).to_s

      source.to_enum(:scan, ujs_data_confirm).map do
        "#{relative}:#{source[0...Regexp.last_match.begin(0)].count("\n") + 1}"
      end
    end

    expect(offenders).to be_empty, <<~MSG
      `data: { confirm: ... }` gefunden:

      #{offenders.map { |o| "  - #{o}" }.join("\n")}

      Turbo liest `data-turbo-confirm`, nicht `data-confirm` — der Dialog
      erscheint sonst nie und die Aktion feuert ungefragt. Bitte auf
      `data: { turbo_confirm: ... }` umstellen. Bei Neo::Buttons::*-Komponenten
      stattdessen den Top-Level-Kwarg `confirm:` nutzen, der intern korrekt auf
      turbo_confirm gemappt wird.
    MSG
  end

  it 'der Scan erfasst ueberhaupt ERB-Dateien (Selbsttest gegen tote Globs)' do
    expect(scanned_files.size).to be > 100
  end
end
