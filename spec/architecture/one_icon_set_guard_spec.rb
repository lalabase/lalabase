# frozen_string_literal: true

require 'rails_helper'

# What:  The application draws its icons from ONE set, Bootstrap Icons. This guard trips
#        when an icon from another set is pasted in, in the shape that has happened.
# Type:  Static guard, without an allowlist. A tripwire for the common case, not a proof.
# Why:   Until 2026-09-30 six files carried nine pasted drawings: Heroicons (a cross, two
#        flash signs, two turning arrows), Lucide (two pins), and the spinner from the
#        Tailwind documentation, twice. Each is somebody's work under its own license,
#        and none of them appeared in THIRD_PARTY_NOTICES.txt, because a pasted path is
#        not a file the license guard can see. Bootstrap Icons has every one of them, is
#        already shipped and already has its notice.
#
# How a pasted icon gives itself away: by its curves. What this application draws itself
# (the plus of the main action, the deadline flag, the view switch, the chevrons) is made
# of straight strokes and basic shapes, a handful of coordinates each. An icon from a set
# is, nearly always, a path with arcs and Béziers.
#
#   icon            -> <i class="bi bi-..."></i>
#   our own drawing -> straight strokes (M, L, H, V) and <rect>, <circle>, <line>
#
# What passes, and has to be caught by the person who reads the diff:
#   * a pasted icon of straight strokes only (a cross, a check mark, a menu);
#   * path data held in a constant or put together at run time;
#   * an SVG file, a sprite behind <use>, an <img> that points to one.
#
# Second rule, about the icons we do use: one that is told to turn names its own box.
module OneIconSetGuard
  # Path data in the spellings it comes in: d="…" in markup (also escaped inside a
  # string), d: '…' and :d => '…' in a tag helper, 'd' => '…', setAttribute('d', '…'),
  # with any of the three quotes, over one line or several. It opens with a move command
  # and a number, which is what tells it from a word that happens to follow a "d:".
  PATH_DATA = /
    (?: \b d \s* (?: = | : | => ) \s* | ['"] d ['"] \s* (?: => | , ) \s* )
    \\? ["'`] \s* ( [Mm] \s* -? [\d.] [^"'`]* )
  /x

  # An arc, a cubic, a smooth cubic, a quadratic or a smooth quadratic command with its
  # first number.
  CURVE = /[aAcCsSqQtT]\s*-?[\d.]/

  # The class of another icon font.
  OTHER_FONT = /class\s*(?:=|:)\s*["'][^"']*(?:\bfa[srlbd]?\s+fa-|\bmaterial-icons\b|\bmdi\s+mdi-|\blucide-|\bheroicon)/

  # A class list that names an icon and lets it turn.
  TURNING_ICON = /["']([^"']*\bbi-[^"']*\banimate-spin\b[^"']*|[^"']*\banimate-spin\b[^"']*\bbi-[^"']*)["']/m
  BOX = /(?:\A|\s)(?:inline-block|block|flex|inline-flex)(?:\s|\z)/

  module_function

  def line_of(text, offset)
    text[0...offset].count("\n") + 1
  end

  def curved?(path_data)
    path_data.match?(CURVE)
  end

  def pasted_icons(path, text)
    text.to_enum(:scan, PATH_DATA).filter_map do
      match = Regexp.last_match
      data = match[1].squish
      "#{path}:#{line_of(text, match.begin(0))}: #{data[0, 48]}#{'…' if data.length > 48}" if curved?(data)
    end
  end

  def other_fonts(path, text)
    text.to_enum(:scan, OTHER_FONT).map { "#{path}:#{line_of(text, Regexp.last_match.begin(0))}: #{Regexp.last_match[0]}" }
  end

  # The quotes inside ERB tags go, so that a class list with a condition in it
  # (class="bi bi-x <%= 'animate-spin' if busy %>") is read as the one list it renders.
  def class_lists(text)
    text.gsub(/<%.*?%>/m) { |erb| erb.tr(%q("'), '  ') }
  end

  # An <i> is an inline box, and a transform does not apply to one. It turns only while
  # its parent happens to be a flex or grid container, which makes an item of it. A sign
  # that names its own box turns wherever it is put.
  def without_a_box(path, text)
    lists = class_lists(text)
    lists.to_enum(:scan, TURNING_ICON).filter_map do
      match = Regexp.last_match
      classes = match[1].squish
      "#{path}:#{line_of(lists, match.begin(0))}: #{classes}" unless classes.match?(BOX)
    end
  end

  def source_files
    Dir.chdir(Rails.root) { Dir['app/**/*.{erb,rb,js,css}'] }.reject { |path| path.start_with?('app/assets/builds/') }
  end

  def scan(rule)
    source_files.flat_map { |path| public_send(rule, path, Rails.root.join(path).read.scrub) }
  end
end

RSpec.describe 'One icon set guard' do
  describe 'a pasted icon' do
    def found(text, path: 'x.erb')
      OneIconSetGuard.pasted_icons(path, text)
    end

    it 'is a path with arcs or Béziers, in any spelling' do
      heroicon = 'M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586z'

      expect(found(%(<path d="#{heroicon}" />))).to contain_exactly(a_string_starting_with('x.erb:1: M10 18a8 8 0 100-16'))
      expect(found(%(<path d=" #{heroicon}"/>)).size).to eq(1)
      expect(found(%(<path\n  d = '#{heroicon}'\n/>)).size).to eq(1)
      expect(found(%(<path d="M10 18a8 8 0 100-16\n  8 8 0 000 16z" />)).size).to eq(1)
      expect(found("tag.path(d: 'M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9')", path: 'x.rb').size).to eq(1)
      expect(found("tag.path(:d => 'M9 10.76a2 2 0 0 1-1.11 1.79')", path: 'x.rb').size).to eq(1)
      expect(found("content_tag(:path, nil, 'd' => 'M4 12C5.373 0 0 5.373 0 12h4z')", path: 'x.rb').size).to eq(1)
      expect(found(%q('<svg><path d=\"M4 12a8 8 0 018-8V0z\"/></svg>'.html_safe), path: 'x.rb').size).to eq(1)
      expect(found("path.setAttribute('d', 'M4 12C5.373 0 0 5.373 0 12h4z')", path: 'x.js').size).to eq(1)
      expect(found('path.setAttribute("d", `M4 12C5.373 0 0 5.373 0 12h4z`)', path: 'x.js').size).to eq(1)
      expect(found(%(background: url("data:image/svg+xml,%3Cpath d='M4 12a8 8 0 018-8'/%3E");), path: 'x.css').size).to eq(1)
    end

    it 'is not a drawing of straight strokes, and not a word behind a "d:"' do
      own = <<~MARKUP
        <path d="M3.5 6l4.5 4.5L12.5 6" />
        tag.path(d: 'M9 2.5v13M2.5 9h13', fill: 'none')
        path.setAttribute('d', 'M10,10 L90,90 M10,90 L90,10');
        <circle cx="25" cy="25" r="22" stroke-width="4" />
        <div data-controller="sortable" id="d" data-d="Master data"></div>
        { h: "Stunden", d: "Minuten" }
        day_names(d: 'Mittwoch')
        tag.path(d: "M\#{cx} \#{cy} A\#{r} \#{r} 0 0 1 \#{x} \#{y}")
      MARKUP

      expect(found(own)).to be_empty
    end
  end

  it 'takes the class of another icon font for what it is' do
    expect(OneIconSetGuard.other_fonts('a.erb', '<i class="fa fa-spinner fa-spin"></i>').size).to eq(1)
    expect(OneIconSetGuard.other_fonts('a.erb', '<span class="material-icons">close</span>').size).to eq(1)
    expect(OneIconSetGuard.other_fonts('a.rb', "tag.i(class: 'fas fa-check')").size).to eq(1)
    expect(OneIconSetGuard.other_fonts('a.erb', '<i class="bi bi-check"></i> <p class="fact far-away">x</p>')).to be_empty
  end

  describe 'a turning icon' do
    def found(text)
      OneIconSetGuard.without_a_box('x.erb', text)
    end

    it 'names no box of its own' do
      expect(found('<i class="bi bi-arrow-repeat animate-spin" aria-hidden="true"></i>')).to eq(['x.erb:1: bi bi-arrow-repeat animate-spin'])
      expect(found(%(el.innerHTML = '<i class="animate-spin bi bi-hourglass-split text-4xl"></i>')).size).to eq(1)
      expect(found(%(<i class="bi bi-arrow-repeat <%= 'animate-spin' if busy %>"></i>)).size).to eq(1)
      expect(found(%(<i\n  class="bi bi-arrow-repeat\n         animate-spin"></i>))).to eq(['x.erb:2: bi bi-arrow-repeat animate-spin'])
    end

    it 'is fine as an inline-block, and a ring of our own is none of its business' do
      turning = <<~MARKUP
        <i class="bi bi-arrow-repeat inline-block animate-spin"></i>
        <i class="bi bi-arrow-repeat text-2xl animate-spin inline-block"></i>
        <i class="bi bi-arrow-repeat inline-block <%= 'animate-spin' if busy %>"></i>
        <span class="block h-4 w-4 rounded-full border-2 animate-spin"></span>
        <i class="bi bi-pin"></i>
      MARKUP

      expect(found(turning)).to be_empty
    end
  end

  it 'reads the files it guards' do
    files = OneIconSetGuard.source_files

    expect(files).to include('app/components/neo/buttons/base.rb', 'app/helpers/tickets_helper.rb',
                             'app/views/layouts/application_sessionless.html.erb',
                             'app/javascript/controllers/tag_input_controller.js',
                             'app/assets/stylesheets/layout.css')
    # Our own drawings are found, so an empty result below is not a vacuum.
    drawings = files.sum { |path| Rails.root.join(path).read.scrub.scan(OneIconSetGuard::PATH_DATA).size }
    expect(drawings).to be > 3
  end

  it 'finds no pasted icon' do
    offenders = OneIconSetGuard.scan(:pasted_icons)

    expect(offenders).to be_empty, <<~MESSAGE
      A path with curves is, nearly always, an icon from somebody's set:

      #{offenders.join("\n")}

      Use Bootstrap Icons, which the application already ships: <i class="bi bi-..."></i>.
      A drawing of our own is made of straight strokes and basic shapes. If it really
      needs a curve (a chart, a gauge), compute the path from numbers in code: a curve
      written out as a literal is what a pasted icon looks like.
    MESSAGE
  end

  it 'finds no other icon font' do
    offenders = OneIconSetGuard.scan(:other_fonts)

    expect(offenders).to be_empty, "Another icon font is in use. The set is Bootstrap Icons:\n#{offenders.join("\n")}"
  end

  it 'finds no turning icon without a box of its own' do
    offenders = OneIconSetGuard.scan(:without_a_box)

    expect(offenders).to be_empty, <<~MESSAGE
      These icons are told to turn and name no box of their own:

      #{offenders.join("\n")}

      An <i> is an inline box, and a transform does not apply to one. It turns only while
      its parent happens to be a flex or grid container. Add inline-block to the class
      list, and it turns wherever it is put.
    MESSAGE
  end
end
