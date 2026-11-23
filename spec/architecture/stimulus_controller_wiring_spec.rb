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
#   3. DEAD ACTIONS — No action names a controller that nothing mounts. Stimulus binds
#      an action only inside an element that mounts its controller and says nothing
#      about one that has none: the click does nothing and logs nothing. In every
#      release up to 2026.11.1 the "Create ticket" button of a new project's empty list
#      stood like that (lalabase/lalabase#259). Its pop-up had become the writing
#      surface, the mount left the page, the action stayed.
#
# Pure file scan, no browser. Knows this repo's mount patterns:
#   - Literal:        data-controller="neo-flash"
#   - Rails hash:     data: { controller: "file-upload" }            (ERB)
#   - DSL/array join: data[:controller] = ['neo-tag', ...].join(' ') (component .rb)
#
# A selector ([data-controller="modal"] in a script) LOOKS FOR a mount, it is not one.
# It counted as one until that button was found, and that alone kept `modal` out of the
# census while no template mounted it. What a script looks for still has to exist
# (invariant 1), and that is all it proves.
#
# ⚠️ Not seen: whether the mount stands ABOVE the action on the page that is rendered
# (a controller mounted on another page only passes), an identifier put together at
# run time, and a mount a script would build (none does). Those are for a browser spec
# of the page: spec/system/ticket_first_use_button_spec.rb clicks the button of #259.
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
    'price-ladder' => 'operator engine view, app/views/admin/price_lists/new.html.erb there',
    # Dead: no template has mounted it since the ticket pop-up became the writing
    # surface. time_session_form_controller.js still LOOKS for it, which this census
    # took for a mount. Goes together with the two actions below that still name it.
    'modal' => 'dead since the writing surface replaced the ticket pop-up; delete with its last actions'
  }.freeze

  # Actions whose controller nothing mounts, by the file they stand in. Per file and
  # not per controller: an entry for the time form must not let the same dead
  # controller through in the ticket list. Only shrinks, every entry with its reason.
  KNOWN_DEAD_ACTIONS = {
    'app/views/organisations/time_sessions/_form.html.erb' => {
      'modal' => "Cancel of a booking's edit form. lib/time_session_modal.js finds that button by its text " \
                 'and gives it a listener of its own; the action never fires'
    },
    'app/views/organisations/time_sessions/_form_fields.html.erb' => {
      'modal' => 'default of cancel_action; each of the three forms passes its own'
    },
    'app/views/organisations/time_sessions/_form_index.html.erb' => {
      'time-session-modal' => 'default of close_action, its controller is deleted. Only an edit request for a frame ' \
                              "renders this form, and the one link that sends it (the pencil of a phone's time " \
                              'card) asks for the list frame, which the answer does not carry'
    }
  }.freeze

  # An action wherever it is written, not only in a data-action attribute or under an
  # action: key: the time forms hand theirs down in a local (cancel_action:), a button
  # component assigns it in Ruby, a template picks it with a condition.
  ACTION_DESCRIPTOR = /->([a-z][a-z0-9]*(?:-[a-z0-9]+)*)#[A-Za-z_]\w*/
  ACTION_ATTRIBUTES = [/data-action=["']([^"']+)["']/, /\baction:\s*["']([^"']+)["']/].freeze
  # An ERB comment explains and renders nothing. The strict-locals line is code: its
  # defaults reach the page.
  ERB_COMMENT = /<%#(?!\s*locals:).*?%>/m

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

  # Identifiers that actually MOUNT a controller: markup only. No script mounts one,
  # and what a script searches for is no mount (selector_hook_identifiers).
  def mounted_identifiers
    valid(mounts_in(markup_blob))
  end

  def mounts_in(markup)
    tokens = []
    add = ->(val) { tokens.concat(val.split(/\s+/)) unless val.match?(ERB_DYNAMIC) }
    # Literal data-controller="a b c"   (skip ERB-interpolated values, and a selector:
    # [data-controller="a"] in an inline script or a stylesheet rule searches)
    markup.scan(/(?<!\[)data-controller=["']([^"']+)["']/).each { |m| add.call(m[0]) }
    # Rails hash / DSL  controller: "a b"  (ERB data hash + component .rb)
    markup.scan(/\bcontroller:\s*["']([^"']+)["']/).each { |m| add.call(m[0]) }
    # Array join  controller... = ['neo-tag', ...]  /  controller: ['x', y]
    markup.scan(/\bcontroller\b[^=\n:]*[:=]\s*\[([^\]]*)\]/).each do |arr|
      arr[0].scan(/["']([^"']+)["']/).each { |t| add.call(t[0]) }
    end
    tokens
  end

  # Selector hook in the JS:  ANOTHER controller uses [data-controller*="x"] as a DOM marker.
  # Comment lines (JSDoc examples) and self-references do NOT count. A reference, not a
  # mount: the element it searches for has to come from a template.
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

  # The source without what only explains: comments render nothing and bind nothing.
  def without_comments(source, file)
    return source.gsub(ERB_COMMENT) { |comment| "\n" * comment.count("\n") } if file.end_with?('.erb')

    marks = file.end_with?('.js') ? ['//', '*', '/*'] : ['#']
    source.lines.reject { |line| line.lstrip.start_with?(*marks) }.join
  end

  # Controller identifiers of every action in one source: "event->identifier#method"
  # wherever it stands, and the short form "identifier#method" in an action attribute.
  def actions_in(source, file)
    code = without_comments(source, file)
    tokens = code.scan(ACTION_DESCRIPTOR).flatten
    ACTION_ATTRIBUTES.each do |attribute|
      code.scan(attribute).each { |m| tokens.concat(m[0].scan(/(?:^|\s|;)([a-z][a-z0-9-]*)#/).flatten) }
    end
    valid(tokens)
  end

  # [relative path, identifier] for every action of markup and scripts.
  def action_sites
    @action_sites ||= (markup_files + js_files).flat_map do |file|
      relative = Pathname.new(file).relative_path_from(Rails.root).to_s
      actions_in(File.read(file), file).map { |identifier| [relative, identifier] }
    end
  end

  def dead_action_sites
    action_sites.reject { |_file, identifier| mounted.include?(identifier) }
  end

  def known_dead_action_sites
    KNOWN_DEAD_ACTIONS.flat_map { |file, entries| entries.keys.map { |identifier| [file, identifier] } }
  end

  let(:controllers) { self.class.controller_identifiers }
  let(:mounted)     { mounted_identifiers }
  let(:allowed)     { KNOWN_EXTERNAL_OR_DANGLING.keys.to_set }

  it 'mountet keinen Controller, der weder existiert noch dokumentiert dangling ist' do
    dangling = (mounted | selector_hook_identifiers) - controllers - allowed
    expect(dangling).to be_empty,
                        "data-controller mountet unbekannte Controller: #{dangling.to_a.sort.inspect}"
  end

  it 'reads a mount and an action where they are written, and takes no search for a mount' do
    template = <<~ERB
      <%# An explanation may quote click->explained#open: it renders nothing. %>
      <%# locals: (cancel_action: "click->from-a-local#close") %>
      <div data-controller="first second">
        <button data-action="click->first#open keydown.esc@window->second#close third#toggle"></button>
        <%= render Button.new(data: { controller: "from-a-hash", action: ("submit->conditional#carry" if lane) }) %>
        <script>document.querySelector('[data-controller="searched-for"]')</script>
      </div>
    ERB
    component = <<~RUBY
      # attrs[:data][:action] = 'click->commented-out#run'
      attrs[:data][:controller] = ['from-an-array', attrs[:data][:controller]].compact.join(' ')
      attrs[:data][:action] = 'click->assigned#run'
    RUBY
    script = <<~JS
      // row.setAttribute("data-action", "click->commented-out#pick")
      row.setAttribute("data-action", "click->from-a-script#pick")
      const popUp = this.element.closest('[data-controller="searched-for"]')
      const rows = document.querySelectorAll('tr[data-controller*="searched-for"], [data-controller~="searched-for"]')
    JS

    # Whatever is read for mounts, a selector is none: the three forms a script writes.
    expect(mounts_in(script)).to be_empty
    expect(valid(mounts_in(template) + mounts_in(component))).to eq(%w[first second from-a-hash from-an-array].to_set)
    expect(actions_in(template, 'page.html.erb')).to eq(%w[first second third conditional from-a-local].to_set)
    expect(actions_in(component, 'component.rb')).to eq(%w[assigned].to_set)
    expect(actions_in(script, 'controller.js')).to eq(%w[from-a-script].to_set)
  end

  it 'names no controller in an action that nothing mounts' do
    unexpected = (dead_action_sites - known_dead_action_sites).sort

    expect(unexpected).to be_empty, <<~MSG
      An action for a controller that no template mounts:

      #{unexpected.map { |file, identifier| "  - #{file}: #{identifier}" }.join("\n")}

      Stimulus binds an action only inside an element that mounts its controller
      (data-controller on that element or on one above it). Without a mount the
      click does nothing and logs nothing. Mount the controller where the action
      stands, or give the button the action or the link that took its place.
    MSG
  end

  it 'keeps the dead-action list clean (no entry without its action)' do
    stale = (known_dead_action_sites - dead_action_sites).sort

    expect(stale).to be_empty, <<~MSG
      KNOWN_DEAD_ACTIONS names an action that is gone, or whose controller is mounted now:

      #{stale.map { |file, identifier| "  - #{file}: #{identifier}" }.join("\n")}

      Remove the entry: the list only shrinks.
    MSG
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
    referenced = mounted | selector_hook_identifiers | action_identifiers
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
