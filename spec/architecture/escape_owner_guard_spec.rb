# frozen_string_literal: true

require 'rails_helper'

# What:  Every script that reacts to Escape says when that Escape is its own, so the
#        detail lane behind a menu, a modal or a drawer stays open
#        (app/javascript/lib/escape_owner.js).
# Type:  Static guard with a closed list of scripts that react to Escape without
#        owning it, each with its reason.
# Why:   Until 2026-10-17 the lane kept its own list of the overlays that may take
#        Escape first, nine CSS selectors written by hand. Every overlay that was not
#        on it closed the lane behind itself: the "Link" modal of a ticket, the "+"
#        modal of "Alle Meetings" (with an unsaved edit in the lane), the value menu of
#        the filter bar. The list asked the wrong place; the owner knows when it is
#        open.
#
#   a Stimulus controller that reacts to Escape -> defines ownsEscape()
#   a script that builds a layer outside any controller -> sets data-owns-escape on it
#
# What passes, and has to be caught by the person who reads the diff: an ownsEscape()
# that answers wrong (true while nothing is open keeps the lane open for good), a key
# read in another spelling than the literal 'Escape' or keyCode 27.
module EscapeOwnerGuard
  ESCAPE_KEY = /(['"`])Esc(?:ape)?\1|keyCode\s*===?\s*27|\.esc\b/
  OWNS_ESCAPE = /^\s+(?:get\s+)?ownsEscape\s*\(\s*\)\s*\{/
  # A Stimulus action bound to the key in markup: keydown.esc->name#method.
  TEMPLATE_ESCAPE = /key(?:down|up)\.esc(?:@\w+)?->([\w-]+)#/
  MARKS_LAYER = /data-owns-escape/

  # Scripts that react to Escape and never own it. Closed: a new script that reacts
  # to Escape answers ownsEscape(), or comes here with its reason.
  NOT_OWNERS = {
    'app/javascript/controllers/layout_toggle_controller.js' =>
      'The lane asks the owners; it is what they are asked about.',
    'app/javascript/controllers/keyboard_navigation_controller.js' =>
      'Escape on a row goes back to the search field and closes the lane with it, ' \
      'as it did before this rule: the row and the lane are left together.',
    'app/javascript/controllers/neo_notification_controller.js' =>
      'Its Escape case does nothing; the bulk selection handles that key.'
  }.freeze

  module_function

  def scripts
    Rails.root.glob('app/javascript/{controllers,lib}/**/*.js').map { |path| path.relative_path_from(Rails.root).to_s }.sort
  end

  def controller?(path) = path.start_with?('app/javascript/controllers/')

  # The controllers that templates bind to the key, by their files.
  def bound_in_templates
    identifiers = Rails.root.glob('app/{views,components}/**/*.{erb,rb}').flat_map { |file| file.read.scan(TEMPLATE_ESCAPE).flatten }
    identifiers.uniq.map { |identifier| "app/javascript/controllers/#{identifier.gsub('--', '/').tr('-', '_')}_controller.js" }
  end

  def source(path) = Rails.root.join(path).read

  def reacts_to_escape?(path) = source(path).match?(ESCAPE_KEY)

  def answers?(path)
    controller?(path) ? source(path).match?(OWNS_ESCAPE) : source(path).match?(MARKS_LAYER)
  end
end

RSpec.describe EscapeOwnerGuard do
  let(:escape_scripts) do
    (described_class.scripts.select { |path| described_class.reacts_to_escape?(path) } +
      described_class.bound_in_templates).uniq.sort
  end

  it 'finds the scripts that react to Escape (the guard is not empty)' do
    expect(escape_scripts).to include('app/javascript/controllers/meeting_modal_controller.js',
                                      'app/javascript/controllers/filter_bar_controller.js',
                                      'app/javascript/lib/time_session_modal.js',
                                      # bound to the key only in its template
                                      'app/javascript/controllers/time_sessions_index_controller.js')
    expect(escape_scripts.size).to be > 30
  end

  it 'has every script that reacts to Escape say when the Escape is its own' do
    silent = escape_scripts.reject do |path|
      described_class.answers?(path) || described_class::NOT_OWNERS.key?(path)
    end

    expect(silent).to be_empty, <<~MSG
      These scripts react to Escape and do not say when it is theirs, so the detail lane
      closes behind them (app/javascript/lib/escape_owner.js):
        #{silent.join("\n  ")}
      A controller defines ownsEscape(): true while its next Escape closes or undoes
      something of its own. A script that builds a layer outside any controller sets
      data-owns-escape on it while it stands. Only if it never owns the key: add it to
      NOT_OWNERS with the reason.
    MSG
  end

  it 'keeps NOT_OWNERS to scripts that still react to Escape and do not own it' do
    described_class::NOT_OWNERS.each do |path, reason|
      expect(Rails.root.join(path)).to exist, "#{path} is gone: remove it from NOT_OWNERS"
      expect(escape_scripts).to include(path), "#{path} no longer reacts to Escape: remove it"
      expect(described_class.answers?(path)).to be(false), "#{path} answers ownsEscape() now: remove it from NOT_OWNERS"
      expect(reason).to be_present
    end
  end

  it 'sees the spellings of the key it claims to see' do
    expect("if (event.key === 'Escape')").to match(described_class::ESCAPE_KEY)
    expect('case "Esc":').to match(described_class::ESCAPE_KEY)
    expect('if (event.keyCode === 27)').to match(described_class::ESCAPE_KEY)
    expect('data-action="keydown.esc@window->x#close"').to match(described_class::ESCAPE_KEY)
    expect('// Escape closes the menu').not_to match(described_class::ESCAPE_KEY)
    expect('keydown.esc@window->neo-writing-surface#escape'[described_class::TEMPLATE_ESCAPE, 1]).to eq('neo-writing-surface')
  end

  it 'finds every controller a template binds to the key' do
    missing = described_class.bound_in_templates.reject { |path| Rails.root.join(path).exist? }

    expect(missing).to be_empty, "Bound to Escape in a template, but no such controller file: #{missing.join(', ')}"
  end
end
