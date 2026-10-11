# frozen_string_literal: true

require 'rails_helper'

# Guard: a page takes its width from the layout, never from a number of its own.
#
# The rule ("Breiten" in the Belegungstabelle, doc/belegungstabelle_oberflaeche.md on
# branch doc/belegungstabelle-oberflaeche) asks one question: does the reader compare
# columns downwards, or read rows across? Comparing needs width, so tables, the board
# and every list-and-lane page carry no cap. Reading needs a limit: a page where each
# row holds one thing with one value is capped at 620 px, at 820 px when its rows carry
# a glyph or a time column. Running text stays at 70ch in every class.
#
# Before the rule had a place for its value, every page chose its own. On 10.09.2026
# five capped pages carried five widths (672, 680, 768, 896, and 896 centred), two of
# them set that same day, while the activity feed had none and ran to 2200 px. So the
# three values live once in layout.css, and a view names the class: .width-capped,
# .width-capped--wide, .width-text.
#
# What this holds, structurally. Nothing here can measure a pixel (system specs do not
# run in CI, and a view is classes, not geometry):
#   1. layout.css defines each value exactly once, no second name in layout.css
#      carries the two page values, and no other stylesheet caps a block at one of
#      them by number.
#   2. An open lane lifts the cap: the split replaces the limit.
#   3. No page template sets a max-w-* of its own, beyond the legacy list below.
#   4. No capped block is centred: capped means ending earlier, never starting
#      elsewhere.
#
# The legacy list is what the page templates carried after the first round
# (11.09.2026), per file and count, and it may only shrink. A file below its listed
# count fails as well, so a fixed page cannot quietly turn into room for the next
# number. The edge guard (spec/views/one_page_edge_guard_spec.rb) starts at zero; this
# one cannot, because 56 widths in 38 templates are 38 readings, not one sweep.
RSpec.describe 'page width guard' do
  let(:stylesheets) { Rails.root.join('app/assets/stylesheets') }
  let(:layout_css) { File.read(stylesheets.join('layout.css')) }
  let(:values) { { '--width-capped' => '620px', '--width-capped-wide' => '820px', '--width-text' => '70ch' } }

  # A max-w-* that sets a width: the named scale, prose, screen sizes and arbitrary
  # values. max-w-full, max-w-none and max-w-min/max/fit do not cap a page.
  let(:own_width) { /\bmax-w-(?:xs|sm|md|lg|xl|[2-7]xl|prose|screen-[a-z0-9]+|\[[^\]]+\])/ }

  # Shrink-only: path => number of own widths on 11.09.2026. Lower the count when a
  # page moves to a class, and delete the line when it reaches zero.
  let(:legacy_widths) do
    {
      'app/views/billing_accounts/index.html.erb' => 1,
      'app/views/organisations/accept_invitations/show.html.erb' => 1,
      'app/views/organisations/ai_configurations/show.html.erb' => 5,
      'app/views/organisations/ai_protocols/show.html.erb' => 2,
      'app/views/organisations/ai_settings/confirm_package.html.erb' => 1,
      'app/views/organisations/ai_settings/show.html.erb' => 2,
      'app/views/organisations/ai_usages/show.html.erb' => 2,
      'app/views/organisations/changelog/show.html.erb' => 3,
      'app/views/organisations/codebase_import_files/preview_import.html.erb' => 1,
      'app/views/organisations/codebase_import_files/preview_tickets.html.erb' => 1,
      'app/views/organisations/codebase_import_files/preview_time_sessions.html.erb' => 1,
      'app/views/organisations/codebase_import_files/rollback.html.erb' => 1,
      'app/views/organisations/codebase_import_files/select_project.html.erb' => 1,
      'app/views/organisations/codebase_import_files/show.html.erb' => 2,
      'app/views/organisations/documentation_sets/new.html.erb' => 1,
      'app/views/organisations/invitations/new.html.erb' => 1,
      'app/views/organisations/new.html.erb' => 1,
      'app/views/organisations/notifications/preferences.html.erb' => 1,
      'app/views/organisations/notifications/ticket_exceptions.html.erb' => 1,
      'app/views/organisations/power_search/index.html.erb' => 1,
      'app/views/organisations/project_permissions/index.html.erb' => 1,
      'app/views/organisations/project_permissions/info.html.erb' => 1,
      'app/views/organisations/project_permissions/time_sessions_settings.html.erb' => 1,
      'app/views/organisations/project_repositories/index.html.erb' => 1,
      'app/views/organisations/project_repositories/index_runs.html.erb' => 1,
      'app/views/organisations/project_repositories/new.html.erb' => 1,
      'app/views/organisations/projects/edit.html.erb' => 4,
      'app/views/organisations/prompt_personas/edit.html.erb' => 1,
      'app/views/organisations/prompt_personas/new.html.erb' => 1,
      'app/views/organisations/roles/edit.html.erb' => 5,
      'app/views/organisations/select.html.erb' => 2,
      'app/views/organisations/ticket_attribute_definitions/edit.html.erb' => 1,
      'app/views/organisations/ticket_attribute_definitions/index.html.erb' => 1,
      'app/views/organisations/ticket_attribute_definitions/merge_option.html.erb' => 1,
      'app/views/organisations/ticket_attribute_definitions/new.html.erb' => 1,
      'app/views/organisations/time_session_groups/customer_export.html.erb' => 1,
      'app/views/organisations/time_session_groups/edit.html.erb' => 1,
      'app/views/organisations/time_session_groups/new.html.erb' => 1
    }
  end

  # Every page template of the application shell: not a partial, not a stream.
  def page_templates
    Dir[Rails.root.join('app/views/{organisations,billing_accounts}/**/[^_]*.html.erb')]
  end

  def relative(path) = Pathname.new(path).relative_path_from(Rails.root).to_s

  # <%# ... %> - a comment naming a class must not count as the class.
  def strip_erb_comments(source) = source.gsub(/<%#.*?%>/m, '')

  def own_widths(path) = strip_erb_comments(File.read(path)).scan(own_width).size

  describe 'the values' do
    it 'are defined once, in layout.css' do
      values.each do |name, value|
        definitions = layout_css.scan(/#{Regexp.escape(name)}\s*:\s*([^;]+);/).flatten.map(&:strip)

        expect(definitions).to eq([value]), <<~MSG
          #{name} must be defined exactly once in layout.css, as #{value}; found #{definitions.inspect}.
          One place for the value is the point of the rule: a second definition is how
          five pages ended up with five widths.
        MSG
      end
    end

    # A second name for the same number is the failure this rule exists for. On
    # 11.09.2026 two sessions built the same brief at once, and one capped the
    # feed with its own `--feed-max: 820px` next to --width-capped-wide. Only the
    # two definitions may declare the values; a media query has no semicolon and
    # is not matched.
    it 'are carried by no second name in layout.css' do
      declarations = layout_css.scan(/[\w-]+\s*:\s*(?:620|820)px\s*;/)

      expect(declarations.size).to eq(2), <<~MSG
        layout.css declares 620px or 820px outside the two definitions:
        #{declarations.inspect}
        Read the variable (var(--width-capped), var(--width-capped-wide)) instead of
        giving the same number a second name.
      MSG
    end

    it 'are not repeated as numbers in another stylesheet' do
      others = Dir[stylesheets.join('**/*.css')].reject { |path| File.basename(path) == 'layout.css' }
      offenders = others.select { |path| File.read(path).match?(/max-width:\s*(?:620|820)px/) }

      expect(offenders.map { |path| relative(path) }).to be_empty, <<~MSG
        A stylesheet caps a block at a page value by number instead of reading the
        variable (var(--width-capped) or var(--width-capped-wide)).
      MSG
    end
  end

  describe 'an open lane' do
    it 'lifts the cap, because the split replaces the limit' do
      lift = /\.layout--lane:not\(\.hide-content\)\s+:is\(\.width-capped,\s*\.width-capped--wide\)\s*\{\s*max-width:\s*none;/

      expect(layout_css).to match(lift), <<~MSG
        The rule that lifts the cap in an open lane is missing from layout.css. Without
        it a capped list (the activity feed) keeps its cap next to an open lane, and a
        gap opens between the two whenever the split is wider than the cap.
      MSG
    end
  end

  describe 'a page template' do
    it 'sets no width of its own beyond the legacy list' do
      offenders = page_templates.filter_map do |path|
        count = own_widths(path)
        allowed = legacy_widths.fetch(relative(path), 0)
        "  #{relative(path)}: #{count} own width(s), #{allowed} allowed" if count > allowed
      end

      expect(offenders).to be_empty, <<~MSG
        A page template sets its own max-w-*. Name the class instead (layout.css,
        "Page widths"): .width-capped (620 px, one thing and one value per row),
        .width-capped--wide (820 px, with a glyph or time column), .width-text (70ch,
        running text), or no cap at all where the page compares columns or has a lane.

        #{offenders.join("\n")}
      MSG
    end

    it 'keeps the legacy list honest: a fixed page takes its line off the list' do
      stale = legacy_widths.filter_map do |path, allowed|
        full = Rails.root.join(path)
        count = File.exist?(full) ? own_widths(full) : 0
        "  #{path}: listed #{allowed}, the file has #{count}" if count < allowed
      end

      expect(stale).to be_empty, <<~MSG
        The legacy list allows more widths than a file still has. Lower the count, or
        delete the line at zero, so the room a fixed page leaves is not a budget for
        the next number.

        #{stale.join("\n")}
      MSG
    end
  end

  describe 'a capped block' do
    it 'is never centred' do
      offenders = Dir[Rails.root.join('app/views/**/*.erb')].filter_map do |path|
        classes = strip_erb_comments(File.read(path)).scan(/class=["']([^"']*)["']/).flatten
        centred = classes.select { |list| list.match?(/\bwidth-(?:capped|text)/) && list.match?(/\bmx-auto\b/) }
        "  #{relative(path)}: #{centred.join(' | ')}" if centred.any?
      end

      expect(offenders).to be_empty, <<~MSG
        A capped block is centred. Capped means the block ends earlier, never that it
        starts elsewhere: it stays on the page edge that title, tabs and tools share.

        #{offenders.join("\n")}
      MSG
    end
  end
end
