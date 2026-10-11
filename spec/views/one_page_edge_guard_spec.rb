# frozen_string_literal: true

require 'rails_helper'

# Guard: one left edge per page, and one owner of it.
#
# The layout gives every page its edge: `main` carries `px-4 lg:px-6`
# (app/views/layouts/application.html.erb), and NeoTitleBoxComponent adds no
# horizontal margin of its own, so a title box lands exactly on it. Title,
# subtitle, tabs, tools, counter, column heads and the first text of every row
# are meant to start there. Nothing is indented that does not belong to
# something.
#
# The times area broke that for months, and the interesting part is HOW. The
# edge had two owners: the title box set its own margin (none), while the tab
# bar inherited an `mx-4 md:mx-5` from the div its caller wrapped it in. Title
# at 24px, tabs at 44px, on the same page — and then the filter card added
# `px-[18px]` on top, so the filter content started at ~39px while the title
# started at 20px. Four left edges on one screen. Management never had the
# problem, for one structural reason: its subnav partial rendered the title box
# AND the bar, so there was only ever one owner.
#
# The fix was to make the times area work the way management already did
# (organisations/shared/_subnav renders both), which is why the assertions below
# are structural rather than measured. Nothing here can measure a pixel: system
# specs do not run in CI, and a request spec sees classes, not geometry. What it
# CAN hold is that the structure which produced the offset cannot come back.
#
# No allowlist, deliberately. Every offender was fixed rather than
# grandfathered, so this guard starts at zero (the same choice
# no_rails_ujs_options_guard_spec documents).
RSpec.describe 'one page edge guard' do
  # The one file that owns the area header.
  let(:subnav_partial) { Rails.root.join('app/views/organisations/shared/_subnav.html.erb') }

  # Everything a page of the organisation area renders.
  def organisation_views
    Dir[Rails.root.join('app/views/organisations/**/*.erb')]
  end

  # Repo-relative, for readable failure messages.
  def relative(path)
    Pathname.new(path).relative_path_from(Rails.root).to_s
  end

  # The PAGE entry points, and only those. The rule is about page segments: the
  # blocks that stack under the title. A margin inside a popover, a modal or a
  # centred empty-state card is a different question and answers to its own
  # container, so widening this to every partial would fail on things that are
  # right (dashboard_configurations/_save_scopes bleeds a popover row to its
  # edge, tickets/_timeline_frame_content centres a card).
  def organisation_pages
    Dir[Rails.root.join('app/views/organisations/**/{index,show,new,edit}.html.erb')]
  end

  def strip_erb_comments(source)
    # <%# ... %> — the reason a comment mentioning a class must not fail the guard.
    source.gsub(/<%#.*?%>/m, '')
  end

  describe 'the second edge' do
    # A POSITIVE margin on BOTH sides (mx-3 and wider) in a page's own class
    # list. That is the shape of a page edge; four things are deliberately not
    # matched, because each means something else:
    #   -mx-4 / lg:-mx-6  the filter stripe bleeds PAST the page edge and pads
    #                     itself back onto it. The opposite move, and the way
    #                     full-bleed is done here.
    #   mx-auto           centring.
    #   mx-1 / mx-2       hairline spacing between two inline things.
    #   ms-* / me-*       one-sided: an icon's gap to its label (me-1), the
    #                     layout's sidebar offset (ms-64). Neither is an edge.
    let(:page_margin) { /(?<![-\w])mx-(?:[3-9]|[1-9]\d+)\b/ }

    it 'is nowhere in the organisation pages' do
      offenders = organisation_pages.filter_map do |path|
        source = strip_erb_comments(File.read(path))
        lines = source.lines.each_with_index.filter_map do |line, i|
          next unless line.scan(/class="([^"]*)"/).flatten.any? { |cls| cls.match?(page_margin) }

          "    #{i + 1}: #{line.strip}"
        end
        next if lines.empty?

        "  #{relative(path)}\n#{lines.join("\n")}"
      end

      expect(offenders).to be_empty, <<~MSG
        A page-level horizontal margin re-opens the second left edge.

        The layout already sets the page edge (main: px-4 lg:px-6). A margin on
        top of it moves this block away from the title, which is the offset this
        guard exists to prevent. Content that must bleed past the edge (the
        filter stripe) uses a NEGATIVE margin plus its own padding, not this.

        #{offenders.join("\n")}
      MSG
    end
  end

  describe 'the owner of the edge' do
    # `<div class="mx-...">` ... `render '.../subnav'` — the exact shape that
    # split title and tabs apart before this guard.
    it 'is the subnav partial itself, never a wrapper at the call site' do
      offenders = organisation_views.filter_map do |path|
        source = strip_erb_comments(File.read(path))
        next unless source.match?(%r{render\s+['"]organisations/shared/\w*subnav['"]})

        # Any element opened with a horizontal margin that is still open when the
        # subnav is rendered would re-create the two-owner split.
        before = source.split(%r{render\s+['"]organisations/shared/\w*subnav['"]}).first
        opened = before.scan(/<(\w+)[^>]*class="[^"]*(?<![-\w])m[xse]-(?:[1-9]\d*|px|auto)\b[^"]*"[^>]*>/)
        closed = before.scan(%r{</(\w+)>})
        relative(path) if opened.size > closed.size
      end

      expect(offenders).to be_empty, <<~MSG
        A caller wraps the subnav in a horizontal margin.

        Title box and tab bar come from organisations/shared/_subnav so that they
        share one left edge. Wrapping the render call puts the bar back on an
        edge of its own — the two-owner split this guard was written for.

        #{offenders.join("\n")}
      MSG
    end
  end

  describe 'a chooser at the end of its row' do
    # A menu that runs off the right of the page is the page edge failing in the
    # other direction. shared/_filter_pill hangs its menu (min 16rem) off one
    # edge of its own pill, so a pill pushed to the end of a row with ms-auto
    # opens across the page boundary unless it says `align: :end`.
    #
    # ⚠️ This catches the mechanically visible case only. The display chooser in
    # the tool row is also at the end, but it gets there by being the last child
    # of a justify-between row, which no static rule can see. That one is held
    # by the comment at its call site.
    it 'opens its menu against that end' do
      offenders = organisation_views.filter_map do |path|
        source = strip_erb_comments(File.read(path))
        # <div class="... ms-auto ...">  ...  render 'shared/filter_pill' ...
        pushed = source.scan(%r{<div[^>]*class="[^"]*\bm[sl]-auto\b[^"]*"[^>]*>(.{0,600}?)</div>}m)
        relative(path) if pushed.any? do |(body)|
          body.include?('shared/filter_pill') && !body.match?(/align:\s*:end/)
        end
      end

      expect(offenders).to be_empty, <<~MSG
        A chooser is pushed to the end of its row but opens leftwards from there.

        Its menu is at least 16rem wide and hangs off the start edge of the pill
        by default. At the end of a row that pill sits on the page edge, so the
        menu opens across it. Pass `align: :end`.

        #{offenders.join("\n")}
      MSG
    end
  end

  # The same rule turned sideways: one surface per content area, and ONE owner
  # of it. The table used to paint cream-50 on itself, so the light area was
  # table-shaped - a card inside a darker frame, its head rule ending at a card
  # width instead of at the column's. Moving the tone inward (to the column) was
  # not enough either: main's own 24px page inset stayed shell-coloured, and so
  # did the grid's column gap, which is three tones across one area. The area is
  # <main>, so <main> carries it and everything inside lies ON it.
  describe 'the content surface' do
    let(:layout_css) { File.read(Rails.root.join('app/assets/stylesheets/layout.css')) }

    # Blocks whose selector is EXACTLY this one: `.list table {` matches,
    # `.list table td {` and `.list table .title-header,` do not.
    def css_blocks(source, selector)
      source.scan(/(?:\A|\n)\s*#{Regexp.escape(selector)}\s*\{([^}]*)\}/m).flatten
    end

    it 'belongs to the content area, and to nothing inside it' do
      area_blocks = css_blocks(layout_css, 'main:has(.layout)')

      expect(area_blocks).not_to be_empty, <<~MSG
        No rule for the content area of a list-and-lane page found at all. If
        the selector changed, point this assertion at the new one instead of
        letting it pass on an empty list.
      MSG

      expect(area_blocks.join).to match(/background\s*:/), <<~MSG
        The content area has no surface, so its own inset and its column gap
        show the shell through.

        Nothing inside can carry this: main's 24px page inset lies outside the
        grid, and the grid's 24px column-gap lets whatever is behind it through.
        Without a surface on <main> the reader gets three tones across one
        content area - inset cream-100, list cream-50, lane white - which is the
        one thing the "one surface" rule forbids.

        It also has to be cream-50 and not the shell tone: the row hover IS
        cream-100. The scale is area cream-50, hover cream-100, selection
        cream-200, and it only works from its bottom step.

        ⚠️ Decided three times. It sat on `.layout`; S1 removed it because back
        then `.column` padded the list 16px in, which made the surface a box
        with a second left edge; it is on <main> now, where the page inset is an
        inset INSIDE the surface instead of a strip of shell beside it.
      MSG

      inner = { '.column.list' => 'the list column', '.list table' => 'the table' }
      offenders = inner.filter_map do |selector, name|
        painted = css_blocks(layout_css, selector).select { |body| body.match?(/background\s*:/) }
        "  #{selector} (#{name}):#{painted.join}" if painted.any?
      end

      expect(offenders).to be_empty, <<~MSG
        Something inside the content area paints a surface of its own.

        Then the light area takes that element's shape - the table painting it
        is how the list got a card whose head rule ended at a card width - and
        two rules carry one tone, which is how they drift apart. The area owns
        it; the rows lie on the area.

        #{offenders.join("\n")}
      MSG
    end
  end

  # The lane (the detail beside the list) is a surface, so it holds its content
  # off its own edges - once, in the column. Its blocks pad themselves
  # vertically and never sideways; two of them doing it produced two left edges
  # INSIDE the lane, with the title at one and the comment field 32px further
  # in.
  describe 'the lane' do
    let(:lane_roots) do
      {
        'app/views/organisations/tickets/_ticket_header_show.html.erb' => /<div id="ticket-header"[^>]*class="([^"]*)"/,
        'app/views/organisations/tickets/_ticket_content_for_frame.html.erb' => /<div class="(ticket-content[^"]*)"/,
        # The knowledge lane (S1 of doc/wissen_als_bahn_plan.md): one root per
        # type, the same on the page and on the frame request.
        'app/views/organisations/notes/_note_show.html.erb' => /<div id="note-header"[^>]*class="([^"]*)"/,
        'app/views/organisations/documents/_document_content_for_frame.html.erb' => /<div class="(document-content[^"]*)"/
      }
    end

    it 'holds its content off its edges once, in the column' do
      offenders = lane_roots.filter_map do |path, pattern|
        classes = strip_erb_comments(File.read(Rails.root.join(path)))[pattern, 1]
        raise "lane root not found in #{path}" if classes.nil?

        "  #{path}: #{classes}" if classes.match?(/(?<![-\w])(?:px|pl|pr|ps|pe)-/)
      end

      expect(offenders).to be_empty, <<~MSG
        A block of the lane pads itself sideways.

        The lane column already holds its content off its edges (layout.css,
        .layout--lane .column.content). A block that adds its own horizontal
        padding starts a second left edge inside the lane - which is exactly
        what .ticket-content did with px-5 lg:px-8 after the header dropped
        its own padding: identifier and title at one edge, comment field and
        history 32px further in.

        #{offenders.join("\n")}
      MSG
    end
  end

  describe 'the tab bar' do
    let(:source) { strip_erb_comments(File.read(subnav_partial)) }
    let(:nav_block) { source[%r{<nav\b.*?</nav>}m] }

    it 'marks the active tab with the edge colour, never with an accent' do
      expect(nav_block).to include('border-ink')

      expect(nav_block).not_to match(/cobalt|\baccent\b|border-lime|border-brand/), <<~MSG
        The active tab wears an accent colour.

        The management bar used to mark active with border-cobalt-600, and
        cobalt-600 IS the accent (--accent in application.tailwind.css). One
        token then carried three meanings: main action (claimed), accent
        (actual), active tab (used). An active tab is edge-strong plus weight.
      MSG
    end

    it 'holds tabs only, so tools stay one row lower' do
      inner = nav_block.gsub(%r{</?(?:nav|ul|li)\b[^>]*>}, '')

      expect(inner).not_to match(/<(?:button|form|input|select|textarea)\b/), <<~MSG
        The tab bar contains a control that is not a tab.

        Tabs are siblings of the page title; tools belong in the row below it.
        A control in the bar makes the bar two things at once, and the row under
        it then has to explain why it is not the tool row.
      MSG
    end

    it 'always carries its own rule and its own gap, whatever follows it' do
      # The class list only: the aria-label next to it is interpolated, and
      # legitimately so.
      nav_classes = nav_block[/<nav\b[^>]*\bclass="([^"]*)"/, 1]

      expect(nav_classes).to include('border-b'), <<~MSG
        The tab bar renders without a rule of its own.

        The active tab's 2px underline sits on that rule via -mb-px. Without it
        the underline docks onto whatever element comes next - which is how a
        full-bleed filter stripe once ended up owning the line a tab was
        underlining, two lines of different owners in one row of pixels.
      MSG

      expect(nav_classes).to match(/\bmb-\d/), <<~MSG
        The tab bar renders without a gap below it.

        The bar looks the same on every page, whatever comes below; what follows
        adapts, never the other way round. A caller that could switch the gap
        off is a caller that can make the bar mean something different per page.
      MSG

      expect(nav_classes).not_to include('<%'), <<~MSG
        The bar's rule or gap is decided by a condition.

        Both are unconditional by design. A `flush:`-style flag here is exactly
        the regression this assertion exists for.
      MSG
    end

    # ⚠️ The bar of saved views lives in app/components, which every other
    # assertion here deliberately does not read - they are about page structure
    # under app/views. The ACTIVE MARKER is not about where a bar lives: a tab
    # marked with the accent is the same drift wherever it is written, and this
    # is the one file that already knows the rule.
    it 'holds for every tab bar in the app, wherever it is written' do
      # A component bar is its template AND its Ruby class: the tab's class
      # list lives in the class (NeoFilterBarComponent::TAB_BASE_CLASSES since
      # #760), the role in the template. Reading the template alone found the
      # underline only while a second element in the template happened to
      # carry it, and an empty list here is what this assertion refuses.
      component_bars = Dir[Rails.root.join('app/components/**/*.erb')].select do |path|
        body = strip_erb_comments(File.read(path))
        rb = path.sub(/\.html\.erb\z/, '.rb')
        body += File.read(rb) if File.exist?(rb)
        body.include?('border-b-2') && body.include?('role="tab"')
      end

      expect(component_bars).not_to be_empty, <<~MSG
        No component tab bar found at all. If NeoFilterBarComponent's view row
        was renamed or moved, point this assertion at the new one instead of
        letting it pass on an empty list.
      MSG

      offenders = component_bars.filter_map do |path|
        source = File.read(path)
        rb = path.sub(/\.html\.erb\z/, '.rb')
        source += File.read(rb) if File.exist?(rb)
        marked_with_edge = source.include?('border-ink') &&
                           !source.match?(/border-(?:cobalt|lime|brand)|border-accent/)
        relative(path) unless marked_with_edge
      end

      expect(offenders).to be_empty, <<~MSG
        A tab bar outside app/views marks its active tab with something other
        than the edge colour.

        Saved views and area navigation look alike on purpose; if one of them
        starts marking active with an accent, the pair drifts exactly the way
        the times and management bars did before they were merged.

        #{offenders.join("\n")}
      MSG
    end

    it 'is the only tab bar the organisation area defines' do
      candidates = organisation_views.reject { |path| path == subnav_partial.to_s }
      others = candidates.filter_map do |path|
        body = strip_erb_comments(File.read(path))
        relative(path) if body.include?('border-b-2') && body.include?('aria-current')
      end

      # organisations/time_session_groups/_navigation is NOT a page tab bar: it
      # switches the VIEW of one billing (chronological / by subject / customer
      # export) and sits beside a section heading, not under the page title. It
      # already marks active with border-ink. Folding it into _subnav would press
      # two different things into one shape.
      expect(others).to eq(['app/views/organisations/time_session_groups/_navigation.html.erb']), <<~MSG
        A second page tab bar appeared, or the view switcher moved.

        Two tab bars are how the accent colour got into the management bar in the
        first place: byte-identical partials, one class apart, and nothing to
        notice the drift. Render organisations/shared/_subnav instead.

        Found: #{others.inspect}
      MSG
    end
  end
end
