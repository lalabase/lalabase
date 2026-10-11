# frozen_string_literal: true

require 'rails_helper'

# Guard: No <style> blocks in views.
#
# CSS belongs in app/assets/stylesheets/* — convention (see CLAUDE.md):
#   - layout.css                  -> global column/layout system, list interactions
#   - views.css                   -> page-specific rules (scoped, thematically grouped)
#   - actiontext.css              -> Trix/rich-text overrides
#   - components/*.css            -> encapsulated components (e.g. custom_select)
#   - style_guide.css             -> only the style-guide layout
#   - application.tailwind.css    -> Tailwind layer (@apply works ONLY here, at build time)
#
# Exception: mailer layouts — e-mail clients do not load external stylesheets,
# so the CSS MUST stay embedded there.
RSpec.describe 'View style block guard' do
  ALLOWED_STYLE_BLOCK_VIEWS = %w[
    app/views/layouts/mailer.html.erb
    app/views/layouts/notification_mailer.html.erb
  ].freeze

  it 'app/views enthaelt keine <style>-Bloecke (Ausnahme: Mailer-Allowlist)' do
    offenders = Dir[Rails.root.join('app/views/**/*.erb')]
                .select { |f| File.read(f).match?(/<style[\s>]/) }
                .map { |f| Pathname.new(f).relative_path_from(Rails.root).to_s }
                .sort

    unexpected = offenders - ALLOWED_STYLE_BLOCK_VIEWS

    expect(unexpected).to be_empty, <<~MSG
      <style>-Bloecke in Views gefunden:

      #{unexpected.map { |f| "  - #{f}" }.join("\n")}

      Bitte das CSS nach app/assets/stylesheets/* verschieben
      (Zuordnung siehe Kommentar in diesem Spec bzw. CLAUDE.md).
      Mailer-Layouts sind die einzige zulaessige Ausnahme (Allowlist oben).
    MSG
  end

  it 'die Allowlist enthaelt nur noch existierende Dateien' do
    stale = ALLOWED_STYLE_BLOCK_VIEWS.reject { |f| File.exist?(Rails.root.join(f)) }
    expect(stale).to be_empty, "Allowlist-Eintraege ohne Datei (bitte entfernen): #{stale.join(', ')}"
  end
end
