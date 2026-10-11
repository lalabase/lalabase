# frozen_string_literal: true

require 'rails_helper'

# Structural guard spec for the Stimulus wiring (see doc/stimulus_cleanup_plan.md).
#
#   1. INVARIANT — No markup mounts/triggers a controller that neither exists as a file
#      nor is documented as external/dangling. Catches orphaned data-controller /
#      data-action after deletions.
#   2. DEAD-MOUNT CENSUS — List of all controllers that are mounted NOWHERE, against a
#      documented allowlist. This way known dead ones don't redden the build, but a NEWLY
#      introduced unmounted controller is flagged immediately.
#
# Pure file scan, no browser. Knows this repo's mount patterns:
#   - Literal:        data-controller="neo-flash"
#   - Rails hash:     data: { controller: "file-upload" }            (ERB)
#   - DSL/array join: data[:controller] = ['neo-tag', ...].join(' ') (component .rb)
#   - Selector hook:  [data-controller*="time-session-row"]          (another controller in the JS)
RSpec.describe 'Stimulus controller wiring', type: :model do
  CONTROLLERS_DIR = Rails.root.join('app/javascript/controllers')
  VALID_IDENT = /\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z/

  # External (gem) or pre-existing dangling mounts without a local controller file.
  # DELIBERATELY documented — NOT part of this cleanup; to be clarified separately.
  KNOWN_EXTERNAL_OR_DANGLING = {
    'nested-form' => 'erwartet Gem stimulus-rails-nested-form (nicht installiert); dangling, smart-folder-form übernimmt die echte Arbeit',
    'mobile-ticket-view' => 'neo_mobile_ticket_view_component rendert Mount, Controller-Datei fehlt (vorbestehend, _index_mobile.html.erb)',
    'neo-repository-connect' => 'neo/repository/connect_component rendert Mount, Controller-Datei fehlt (vorbestehend/WIP, project_repositories)',
    'neo-notification-action' => 'neo_notification_component Mark-Read-Button mountet Controller, der fehlt; Funktion läuft über remote:true (vorbestehend)'
  }.freeze

  # Controllers without a detectable mount. Every entry deliberately noted.
  # On deletion the file vanishes -> remove the entry here too (test 4 enforces that).
  # Empty = every controller is (statically provable) mounted. New dead ones surface via test 3.
  KNOWN_UNMOUNTED = {
    # Mounted by app/views/admin/price_lists/new.html.erb of the operator engine
    # (gboyke/lalabase-operator, S3.2 of doc/oss_core_split_plan.md). The engine
    # ships no assets of its own (plan 9.1 "as built"), so the controller stays
    # here and this scan, which reads only core views, cannot see its mount.
    'price-ladder' => 'operator engine view, app/views/admin/price_lists/new.html.erb there'
  }.freeze

  CRUFT = /\.(backup|bak|orig)\z|~\z/

  # Relative ES-module imports ("../mixins/swipeable", "./util") are FORBIDDEN in this app.
  # They bypass importmap resolution: the browser resolves them against the importing
  # module's DIGESTED URL, yielding an undigested path like /assets/mixins/swipeable that
  # 404s in production -> "TypeError: Importing a module script failed". Every cross-module
  # import must use a bare specifier pinned in config/importmap.rb (e.g. "mixins/swipeable").
  # See root CLAUDE.md "Stimulus Controller Index Bug". Empty allowlist = zero tolerance.
  KNOWN_RELATIVE_IMPORTS = {}.freeze
  RELATIVE_IMPORT = %r{(?:\bfrom\s*|\bimport\s*\(?\s*)["']\.\.?/}

  def self.controller_identifiers
    Dir[CONTROLLERS_DIR.join('*_controller.js')].map do |f|
      File.basename(f, '_controller.js').tr('_', '-')
    end.to_set
  end

  # Markup sources: views + components + helpers, WITHOUT cruft and WITHOUT style-guide docs
  # (the style guide contains HTML-escaped code examples that are not real mounts).
  def markup_files
    @markup_files ||= [
      Rails.root.join('app/views'),
      Rails.root.join('app/components'),
      Rails.root.join('app/helpers')
    ].flat_map { |d| Dir[d.join('**/*')] }
     .select { |f| File.file?(f) }
     .reject { |f| f.match?(CRUFT) }
     .reject { |f| f.include?('/views/style_guide/') }
  end

  def js_files
    @js_files ||= Dir[Rails.root.join('app/javascript/**/*.js')]
                  .select { |f| File.file?(f) }.reject { |f| f.match?(CRUFT) }
  end

  def markup_blob
    @markup_blob ||= markup_files.map { |f| File.read(f) }.join("\n")
  end

  def js_blob
    @js_blob ||= js_files.map { |f| File.read(f) }.join("\n")
  end

  def valid(tokens)
    tokens.select { |t| t.match?(VALID_IDENT) }.to_set
  end

  ERB_DYNAMIC = /<%|%>|#\{/

  # Identifiers that actually MOUNT a controller
  def mounted_identifiers
    tokens = []
    add = ->(val) { tokens.concat(val.split(/\s+/)) unless val.match?(ERB_DYNAMIC) }
    # Literal data-controller="a b c"   (skip ERB-interpolated values)
    markup_blob.scan(/data-controller=["']([^"']+)["']/).each { |m| add.call(m[0]) }
    # Rails hash / DSL  controller: "a b"  (ERB data hash + component .rb)
    markup_blob.scan(/\bcontroller:\s*["']([^"']+)["']/).each { |m| add.call(m[0]) }
    # Array join  controller... = ['neo-tag', ...]  /  controller: ['x', y]
    markup_blob.scan(/\bcontroller\b[^=\n:]*[:=]\s*\[([^\]]*)\]/).each do |arr|
      arr[0].scan(/["']([^"']+)["']/).each { |t| add.call(t[0]) }
    end
    valid(tokens) | selector_hook_identifiers
  end

  # Selector hook in the JS:  ANOTHER controller uses [data-controller*="x"] as a DOM marker.
  # Comment lines (JSDoc examples) and self-references do NOT count.
  def selector_hook_identifiers
    tokens = []
    js_files.each do |f|
      own = File.basename(f, '_controller.js').tr('_', '-')
      File.foreach(f) do |line|
        s = line.lstrip
        next if s.start_with?('//', '*', '/*')

        line.scan(/data-controller[*^$~|]?=\\?["']([a-z][a-z0-9-]*)/) do |m|
          tokens << m[0] unless m[0] == own
        end
      end
    end
    valid(tokens)
  end

  # Controller identifiers from data-action / action: "evt->identifier#method"
  def action_identifiers
    tokens = []
    extract = lambda do |val|
      val.scan(/(?:^|\s|;)(?:[\w.:@!-]+->)?([a-z][a-z0-9-]*)#/).each { |m| tokens << m[0] }
    end
    markup_blob.scan(/data-action=["']([^"']+)["']/).each { |m| extract.call(m[0]) }
    markup_blob.scan(/\baction:\s*["']([^"']+)["']/).each { |m| extract.call(m[0]) }
    valid(tokens)
  end

  let(:controllers) { self.class.controller_identifiers }
  let(:mounted)     { mounted_identifiers }
  let(:allowed)     { KNOWN_EXTERNAL_OR_DANGLING.keys.to_set }

  it 'mountet keinen Controller, der weder existiert noch dokumentiert dangling ist' do
    dangling = mounted - controllers - allowed
    expect(dangling).to be_empty,
                        "data-controller mountet unbekannte Controller: #{dangling.to_a.sort.inspect}"
  end

  it 'hat keine data-action auf einen unbekannten Controller' do
    dangling = action_identifiers - controllers - allowed
    expect(dangling).to be_empty,
                        "data-action zeigt auf unbekannte Controller: #{dangling.to_a.sort.inspect}"
  end

  it 'hat keine ungemounteten Controller außer den dokumentierten (Dead-Mount-Census)' do
    never_mounted = (controllers - mounted).to_a.sort
    unexpected = never_mounted - KNOWN_UNMOUNTED.keys
    expect(unexpected).to be_empty, <<~MSG
      Neue Controller ohne erkennbaren Mount (nicht in KNOWN_UNMOUNTED):
        #{unexpected.inspect}
      Entweder verdrahten oder als tot dokumentieren. Voller Census:
        #{never_mounted.inspect}
    MSG
  end

  it 'hält die KNOWN_UNMOUNTED-Allowlist sauber (kein veralteter Eintrag)' do
    never_mounted = controllers - mounted
    stale = KNOWN_UNMOUNTED.keys.reject { |id| controllers.include?(id) && never_mounted.include?(id) }
    expect(stale).to be_empty,
                     "KNOWN_UNMOUNTED veraltet (Datei gelöscht oder jetzt gemountet): #{stale.inspect}"
  end

  it 'hält die EXTERNAL/DANGLING-Allowlist sauber (kein veralteter Eintrag)' do
    referenced = mounted | action_identifiers
    stale = KNOWN_EXTERNAL_OR_DANGLING.keys.reject { |id| referenced.include?(id) }
    expect(stale).to be_empty,
                     "EXTERNAL/DANGLING veraltet (nicht mehr referenziert): #{stale.inspect}"
  end

  # Regression guard (2026-07-14): neo_notification_controller imported "../mixins/swipeable"
  # relatively -> 404 /assets/mixins/swipeable in production, broke controller registration.
  it 'benutzt keine relativen ES-Modul-Imports (die brechen die Importmap-Auflösung in Prod)' do
    offenders = js_files.each_with_object([]) do |f, acc|
      rel = Pathname.new(f).relative_path_from(Rails.root).to_s
      next if KNOWN_RELATIVE_IMPORTS.key?(rel)

      File.foreach(f).with_index(1) do |line, no|
        s = line.lstrip
        next if s.start_with?('//', '*', '/*') # JSDoc/comment examples don't execute

        acc << "#{rel}:#{no}  #{line.strip}" if line.match?(RELATIVE_IMPORT)
      end
    end
    expect(offenders).to be_empty, <<~MSG
      Relative Imports gefunden — auf gepinnte bare specifier umstellen (config/importmap.rb):
        #{offenders.join("\n  ")}
    MSG
  end
end
