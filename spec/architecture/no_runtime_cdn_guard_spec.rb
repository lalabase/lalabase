# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# What:  The scripts, stylesheets and fonts of this application, and the markup of its own
#        templates, make no browser load from a foreign host.
# Type:  Static guard. One named exception (SAMPLES), no allowlist beyond it.
# Why:   Every frontend dependency is served by the instance since 06/2026. The rule stood
#        in a comment of the content security policy, and that policy only REPORTS
#        (config/initializers/content_security_policy.rb): it blocks nothing. Until
#        2026-09-30 the vendored Markdown editor of the old note form fetched a spelling
#        dictionary from jsDelivr and an icon font from BootstrapCDN on every full load of
#        that page, because both addresses sat inside its minified file and both features
#        are on by default. Nobody saw it, since the file was "local".
#
# Three questions:
#   1. Does a tag, a stylesheet, an import or a request in a script name a foreign address
#      as a literal? (our own files and the vendored ones)
#   2. Does one of those files carry the address of a public CDN at all? A list of hosts,
#      incomplete by nature, for the case the first question cannot see.
#   3. The same two for the scripts and stylesheets that GEMS put into the page (Turbo,
#      Stimulus, Action Text, Lexxy): they are not in this repository, and a gem update
#      changes them.
#
# What this does NOT see:
#   * an address built at run time ("#{HOST}/logo.png", a host in a constant);
#   * CONTENT. A synced documentation page shows its images from the repository host
#     (ProjectRepository#raw_file_url, raw.githubusercontent.com), and a Markdown image
#     with an absolute address stays as its author wrote it. `img-src` allows any https.
#     That is the content's address, not the application's, and it is a decision of its
#     own.
#
# A comment that quotes such a tag or address trips the guard as well. Describe it in
# words.
module NoRuntimeCdnGuard
  OWN = %r{\A(app/(assets|javascript|views|components|helpers|controllers)|vendor/(assets|javascript))/.*\.(js|css|erb|html|rb)\z}
  IMPORTMAP = 'config/importmap.rb'

  # Code samples the style guide prints as text and never renders. One of them shows the
  # very thing this guard forbids (an avatar fetched from a foreign host), as the example
  # of what not to write. The views that print them are read like every other view.
  SAMPLES = ['app/controllers/style_guide_controller.rb'].freeze

  FOREIGN = %r{\A\s*(?:https?:|wss?:)?//}i
  START = %q{["'`](?:https?:|wss?:)?//}

  # A tag with its attributes, quotes respected: a Stimulus action holds a ">" inside one.
  TAG = /<(script|link|img|iframe|video|audio|source|embed|object|track)\b((?:"[^"]*"|'[^']*'|[^>"'])*)>/im
  ATTRIBUTE = /(?:\A|\s)(src|srcset|href|data|poster|rel)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/im
  # A <link> that fetches nothing.
  QUIET_REL = /\b(?:canonical|alternate|author|license|help|next|prev|me)\b/i

  HELPERS = 'stylesheet_link_tag|javascript_include_tag|preload_link_tag|image_tag|video_tag|audio_tag|favicon_link_tag'
  MEDIA = 'script|img|iframe|video|audio|source|embed|object|link'

  CALLS = {
    'asset tag helper' => /\b(?:#{HELPERS})\b[^\n]*?#{START}/i,
    'tag builder' => /\b(?:tag\.(?:#{MEDIA})|content_tag\s*\(?\s*:(?:#{MEDIA}))\b[^\n]*?\b(?:src|href|data|poster)(?::|\s*=>)\s*#{START}/i,
    'CSS import' => %r{@import\s+(?:url\(\s*)?["']?(?:https?:)?//}i,
    # Not `new URL("https://…")`: a script that builds an address fetches nothing by it.
    'CSS url()' => %r{(?<!new )\b(?:url|image-set)\(\s*["']?(?:https?:)?//}i,
    'JavaScript import' => /\b(?:from|import)\s*\(?\s*#{START}/,
    'request from a script' => /\b(?:fetch|importScripts|sendBeacon)\s*\(\s*#{START}/,
    'XMLHttpRequest' => /\.open\s*\(\s*["'`][A-Za-z]+["'`]\s*,\s*#{START}/,
    'worker or socket' => /\bnew\s+(?:Worker|SharedWorker|WebSocket|EventSource)\s*\(\s*#{START}/,
    'element source set by a script' => /\.src\s*=\s*#{START}/,
    'stylesheet set by a script' => /\.href\s*=\s*#{START}[^"'`\s]*\.css\b/,
    'importmap pin' => /\bpin\b[^\n]*(?:\bto:|:to\s*=>)\s*#{START}/i
  }.freeze

  # In a template a helper call may run over several lines, up to the end of its ERB tag.
  HELPER_IN_ERB = /\b(?:#{HELPERS})\b(?:(?!%>).)*?#{START}/im

  PUBLIC_CDN = %r{(?:https?:)?//[a-z0-9.-]*(?:
    jsdelivr\.net | esm\.run | unpkg\.com | cdnjs\.cloudflare\.com | bootstrapcdn\.com |
    fonts\.googleapis\.com | fonts\.gstatic\.com | ajax\.googleapis\.com | www\.gstatic\.com |
    fonts\.bunny\.net | use\.typekit\.net | polyfill\.io |
    cdn\.tailwindcss\.com | code\.jquery\.com | esm\.sh | skypack\.dev | jspm\.io |
    fontawesome\.com | rawgit\.com | githack\.com
  )}xi

  module_function

  def tracked_files
    output, status = Open3.capture2('git', 'ls-files', '-z', chdir: Rails.root.to_s)
    raise "git ls-files failed in #{Rails.root}" unless status.success?

    output.split("\0")
  end

  def own_files
    tracked_files.select { |path| path.match?(OWN) || path == IMPORTMAP } - SAMPLES
  end

  # The scripts and stylesheets a gem puts into the page: what the importmap pins and what
  # the stylesheet bundle requires, as far as the file is not one of ours.
  def gem_files
    environment = Rails.application.assets
    pinned = Rails.application.importmap.packages.values.map(&:path).uniq
                  .filter_map { |path| environment.find_asset(path)&.filename }
    bundled = Array(environment.find_asset('application.css')&.metadata&.fetch(:included, nil))
              .map { |uri| uri.sub(%r{\Afile://}, '').sub(/\?.*\z/, '') }
    not_ours((pinned + bundled).uniq, tracked_files)
  end

  # Ours is what git tracks. NOT "what lies under the root": a bundle installed into the
  # checkout (vendor/bundle, as CI does) lies under it and is a gem's all the same.
  def not_ours(files, tracked)
    ours = tracked.to_set { |path| Rails.root.join(path).to_s }
    files.reject { |file| ours.include?(file) }
  end

  def line_of(text, offset)
    text[0...offset].count("\n") + 1
  end

  # ERB tags blanked out, line for line: what is left is the markup the template itself
  # writes, and no "%>" ends a tag early.
  def markup(text)
    text.gsub(/<%.*?%>/m) { |erb| erb.gsub(/[^\n]/, ' ') }
  end

  def foreign_tags(text)
    clean = markup(text)
    clean.to_enum(:scan, TAG).filter_map do
      match = Regexp.last_match
      attributes = match[2].scan(ATTRIBUTE).to_h { |name, *values| [name.downcase, values.compact.first.to_s] }
      next if match[1].casecmp?('link') && attributes['rel'].to_s.match?(QUIET_REL)

      addresses = attributes.except('rel', 'srcset').values + attributes['srcset'].to_s.split(',')
      [line_of(clean, match.begin(0)), "<#{match[1].downcase}> tag"] if addresses.any? { |address| address.match?(FOREIGN) }
    end
  end

  def foreign_calls(path, text)
    patterns = path.end_with?('.erb') ? CALLS.merge('asset tag helper' => HELPER_IN_ERB) : CALLS
    patterns.flat_map do |label, pattern|
      text.to_enum(:scan, pattern).map { [line_of(text, Regexp.last_match.begin(0)), label] }
    end
  end

  # "path:line: what" for everything in a text that makes the browser load from elsewhere.
  def loads(path, text)
    (foreign_tags(text) + foreign_calls(path, text)).uniq.sort.map { |line, label| "#{path}:#{line}: #{label}" }
  end

  def cdn_addresses(path, text)
    text.to_enum(:scan, PUBLIC_CDN).map { "#{path}:#{line_of(text, Regexp.last_match.begin(0))}: #{Regexp.last_match[0]}" }.uniq
  end

  def read(path)
    File.read(path.start_with?('/') ? path : Rails.root.join(path)).scrub
  end
end

RSpec.describe 'No runtime CDN guard' do
  def loads(text, path: 'x.html.erb')
    NoRuntimeCdnGuard.loads(path, text).map { |hit| hit.split(': ').last }
  end

  describe 'the detection in markup' do
    it 'sees a foreign address where the browser fetches it' do
      expect(loads('<script src="https://cdn.example/x.js"></script>')).to eq(['<script> tag'])
      expect(loads('<link rel="stylesheet" href="//cdn.example/x.css">')).to eq(['<link> tag'])
      expect(loads('<link rel="preconnect" href="https://fonts.example">')).to eq(['<link> tag'])
      expect(loads('<img src="https://cdn.example/logo.png" alt="">')).to eq(['<img> tag'])
      expect(loads('<img srcset="/a.png 1x, https://cdn.example/a@2x.png 2x" alt="">')).to eq(['<img> tag'])
      expect(loads('<video poster="https://cdn.example/p.jpg" src="/v.mp4"></video>')).to eq(['<video> tag'])
      expect(loads('<iframe title="x" src=//player.example/embed/1></iframe>')).to eq(['<iframe> tag'])
    end

    it 'sees it across lines, behind an ERB tag and behind a Stimulus action' do
      expect(loads(%(<script\n  defer\n  src="https://cdn.example/x.js"></script>))).to eq(['<script> tag'])
      expect(loads('<img class="<%= css %>" src="https://cdn.example/a.png">')).to eq(['<img> tag'])
      expect(loads('<img data-action="click->zoom#open" src="https://cdn.example/a.png">')).to eq(['<img> tag'])
      expect(NoRuntimeCdnGuard.loads('x.html.erb', %(<p>one</p>\n<p>two</p>\n<script\n src="//cdn.example/x.js"></script>)))
        .to eq(['x.html.erb:3: <script> tag'])
    end

    it 'leaves our own addresses, plain links and quiet <link>s alone' do
      expect(loads('<script src="/assets/application.js"></script>')).to be_empty
      expect(loads('<a href="https://example.com/imprint">Imprint</a>')).to be_empty
      expect(loads('<link rel="canonical" href="https://example.com/page">')).to be_empty
      expect(loads('<img src="<%= avatar_url %>" alt="">')).to be_empty
      expect(loads('<svg xmlns="http://www.w3.org/2000/svg"></svg>')).to be_empty
    end
  end

  describe 'the detection in calls' do
    it 'sees the helpers, in one line and over several in a template' do
      expect(loads('<%= stylesheet_link_tag "https://cdn.example/x.css" %>')).to eq(['asset tag helper'])
      expect(loads(%(<%= stylesheet_link_tag "application",\n      "https://cdn.example/x.css" %>))).to eq(['asset tag helper'])
      expect(loads('image_tag("https://cdn.example/logo.png", alt: "")', path: 'x.rb')).to eq(['asset tag helper'])
      expect(loads("tag.script(src: 'https://cdn.example/x.js')", path: 'x.rb')).to eq(['tag builder'])
      expect(loads("content_tag(:img, nil, src: 'https://cdn.example/a.png')", path: 'x.rb')).to eq(['tag builder'])
    end

    it 'sees stylesheets, imports and pins' do
      expect(loads('@import url("https://cdn.example/x.css");', path: 'x.css')).to include('CSS import')
      expect(loads('src: url(https://cdn.example/x.woff2) format("woff2");', path: 'x.css')).to eq(['CSS url()'])
      expect(loads('background: image-set("https://cdn.example/a.png" 1x);', path: 'x.css')).to eq(['CSS url()'])
      expect(loads('import picker from "https://cdn.example/picker.js"', path: 'x.js')).to eq(['JavaScript import'])
      expect(loads('const m = await import(`https://cdn.example/m.js`)', path: 'x.js')).to eq(['JavaScript import'])
      expect(loads("pin 'picker', to: 'https://cdn.example/picker.js'", path: 'config/importmap.rb')).to eq(['importmap pin'])
      expect(loads("pin 'picker', :to => 'https://cdn.example/picker.js'", path: 'config/importmap.rb')).to eq(['importmap pin'])
    end

    it 'sees a request a script makes on its own' do
      expect(loads('fetch("https://api.example/data.json")', path: 'x.js')).to eq(['request from a script'])
      expect(loads('n.open("GET","https://cdn.example/en_US.aff",!0)', path: 'x.js')).to eq(['XMLHttpRequest'])
      expect(loads('new WebSocket("wss://push.example/socket")', path: 'x.js')).to eq(['worker or socket'])
      expect(loads('s.src="https://cdn.example/x.js";document.head.appendChild(s)', path: 'x.js')).to eq(['element source set by a script'])
      expect(loads('l.rel="stylesheet",l.href="https://cdn.example/font-awesome.min.css"', path: 'x.js')).to eq(['stylesheet set by a script'])
    end

    it 'leaves our own calls alone' do
      expect(loads('<%= image_tag avatar_url, alt: "" %>')).to be_empty
      expect(loads('<%= stylesheet_link_tag "application" %> <a href="https://example.com">x</a>')).to be_empty
      expect(loads('src: url("/fonts/lalabase/archivo-latin.woff2") format("woff2");', path: 'x.css')).to be_empty
      expect(loads('background: url(data:image/svg+xml;base64,AAAA);', path: 'x.css')).to be_empty
      expect(loads('import { Controller } from "@hotwired/stimulus"', path: 'x.js')).to be_empty
      expect(loads('fetch(this.urlValue); link.href = "https://example.com/help"', path: 'x.js')).to be_empty
      expect(loads('const n = new URL("https://lexical.dev/docs/error")', path: 'x.js')).to be_empty
      expect(loads("pin 'sortablejs', preload: false # @1.15.2", path: 'config/importmap.rb')).to be_empty
    end
  end

  it 'finds a public CDN inside a minified line, and no other address' do
    minified = 'e.open("POST",u);var d="https://cdn.jsdelivr.net/codemirror.spell-checker/latest/en_US.aff"'

    expect(NoRuntimeCdnGuard.cdn_addresses('x.min.js', minified)).to eq(['x.min.js:1: https://cdn.jsdelivr.net'])
    expect(NoRuntimeCdnGuard.cdn_addresses('x.js', '// see https://github.com/SortableJS/Sortable')).to be_empty
  end

  describe 'our own files and the vendored ones' do
    let(:files) { NoRuntimeCdnGuard.own_files }

    it 'are read' do
      expect(files).to include('app/views/layouts/application.html.erb', 'app/javascript/application.js',
                               'vendor/javascript/slim-select.js', 'vendor/assets/javascripts/alpinejs.min.js',
                               'app/components/neo/buttons/base.rb', 'app/helpers/application_helper.rb',
                               'app/controllers/organisations/notes_controller.rb', 'config/importmap.rb')
      expect(files.size).to be > 500
      # The exception is a file that exists, and only that one.
      expect(NoRuntimeCdnGuard::SAMPLES).to all(satisfy { |path| Rails.root.join(path).file? })
      expect(files & NoRuntimeCdnGuard::SAMPLES).to be_empty
    end

    it 'fetch from no foreign host' do
      offenders = files.flat_map { |path| NoRuntimeCdnGuard.loads(path, NoRuntimeCdnGuard.read(path)) }

      expect(offenders).to be_empty, <<~MESSAGE
        The browser would load from a foreign host:

        #{offenders.join("\n")}

        Vendor the file (vendor/javascript or vendor/assets, with a notice in
        THIRD_PARTY_NOTICES.txt) and serve it from the instance.
      MESSAGE
    end

    it 'carry no address of a public CDN' do
      offenders = files.flat_map { |path| NoRuntimeCdnGuard.cdn_addresses(path, NoRuntimeCdnGuard.read(path)) }

      expect(offenders).to be_empty, <<~MESSAGE
        A shipped file names a public CDN. In a vendored library that is usually a feature
        which downloads something at run time and is on by default:

        #{offenders.join("\n")}

        Switch the feature off where the library is started, or take a build without it.
        The content security policy does not stop the request: it only reports.
      MESSAGE
    end
  end

  describe 'the scripts and stylesheets of gems' do
    let(:files) { NoRuntimeCdnGuard.gem_files }

    # CI installs the bundle INTO the checkout (vendor/bundle, bundler-cache). "Outside
    # the repository" therefore cannot mean "outside the directory": with that reading
    # the guard found no gem file at all there and turned the build red on main
    # (2026-09-30, the run of #946). What is ours is what git tracks.
    it 'are told from our own by what git tracks, not by where they lie' do
      root = Rails.root.to_s
      in_checkout = "#{root}/vendor/bundle/ruby/4.0.0/gems/lexxy-0.9.18/app/assets/javascript/lexxy.js"
      elsewhere = '/opt/gems/turbo-rails-2.0.13/app/assets/javascripts/turbo.min.js'
      ours = "#{root}/app/javascript/application.js"

      expect(NoRuntimeCdnGuard.not_ours([in_checkout, elsewhere, ours], ['app/javascript/application.js']))
        .to eq([in_checkout, elsewhere])
    end

    it 'are found' do
      expect(files.map { |file| File.basename(file) })
        .to include('turbo.min.js', 'stimulus.min.js', 'actiontext.esm.js', 'lexxy.js', 'lexxy-editor.css')
    end

    it 'fetch from no foreign host and carry no address of a public CDN' do
      offenders = files.flat_map do |file|
        text = NoRuntimeCdnGuard.read(file)
        name = file.sub(%r{\A.*/gems/}, '')
        NoRuntimeCdnGuard.loads(name, text) + NoRuntimeCdnGuard.cdn_addresses(name, text)
      end

      expect(offenders).to be_empty, <<~MESSAGE
        A gem ships a script or stylesheet into the page that loads from a foreign host:

        #{offenders.join("\n")}

        This usually arrives with a gem update. Find the option that switches it off, or
        stay on the version before.
      MESSAGE
    end
  end
end
