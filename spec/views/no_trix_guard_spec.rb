# frozen_string_literal: true

require 'rails_helper'

# What:  Trix is gone; Lexxy is the only rich-text editor, always called through
#        lexxy_rich_text_area with lexxy_embed_editor_options.
# Type:  Static guard (doc/inline_bilder_paket_2_plan.md, P2-E1, 2026-08-23).
# Why:   A bare `rich_text_area` would render Trix again (the gem is still a dependency of
#        actiontext) without the image rule, the zoom wrapper or the upload courtesy check,
#        and a stray `import "trix"` would bring the old global file blocker back. The
#        Lexxy alias is deliberately off (config/initializers/lexxy.rb), so the call site
#        has to be explicit; this guard keeps it that way.
RSpec.describe 'No Trix, Lexxy only' do
  let(:app_files) { Dir[Rails.root.join('app/**/*.{rb,erb,js,css}')].reject { |f| f.include?('/assets/builds/') } + Dir[Rails.root.join('config/{importmap.rb,initializers/*.rb}')] }

  # Every template that can render an editor: views AND ViewComponent templates. A
  # component is a form partial like any other; leaving app/components out would be a
  # hole in the net, not a scope decision.
  def editor_templates
    Dir[Rails.root.join('app/{views,components}/**/*.erb')]
  end

  # The detection, as a function, so the mutation probe below can plant an offender and
  # see the guard react. NOTE the bare count is NOT corrected by the Lexxy count: \b does
  # not match between `lexxy_` and `rich_text_area` (the underscore is a word character),
  # so the bare pattern never sees a Lexxy call in the first place. Subtracting anyway
  # would cancel one real offender per Lexxy editor in the same file, and that shape --
  # one Lexxy editor plus one bare call -- is every converted form in this app.
  def offences_in(source)
    {
      bare: source.scan(/\brich_text_area\b/).size,
      without_options: source.scan(/\blexxy_rich_text_area\b/).size - source.scan(/lexxy_embed_editor_options/).size
    }
  end

  it 'has no Trix import, pin, element or event left in app/ and config/' do
    offenders = app_files.filter_map do |file|
      lines = File.readlines(file).each_with_index.select do |line, _|
        line.match?(/\btrix(-|_)?(editor|toolbar|file-accept|initialize|form|content)\b|import "trix"|pin 'trix'|require trix/i)
      end
      next if lines.empty?

      "#{file.delete_prefix(Rails.root.to_s)}: #{lines.map { |_, i| i + 1 }.join(',')}"
    end

    expect(offenders).to be_empty
  end

  it 'renders every rich text editor through lexxy_rich_text_area with the embed options' do
    offenders = editor_templates.filter_map do |file|
      counts = offences_in(File.read(file))
      next if counts[:bare] <= 0 && counts[:without_options] <= 0

      "#{file.delete_prefix(Rails.root.to_s)} (bare: #{counts[:bare]}, without options: #{counts[:without_options]})"
    end

    expect(offenders).to be_empty
  end

  # Mutation probe. A guard that never fails on a planted offender proves nothing, and
  # both plants sit NEXT TO a correct Lexxy call on purpose: that is the file shape all
  # eight converted forms have, and the shape an arithmetic correction silently swallows.
  describe 'the detection itself' do
    it 'flags a bare rich_text_area even next to a correct Lexxy editor' do
      source = <<~ERB
        <%= form.lexxy_rich_text_area :content, **lexxy_embed_editor_options %>
        <%= form.rich_text_area :notes %>
      ERB

      expect(offences_in(source)[:bare]).to eq(1)
    end

    it 'flags a Lexxy editor rendered without the embed options' do
      source = <<~ERB
        <%= form.lexxy_rich_text_area :content, **lexxy_embed_editor_options %>
        <%= form.lexxy_rich_text_area :summary %>
      ERB

      expect(offences_in(source)[:without_options]).to eq(1)
    end

    it 'stays silent on a file that only uses Lexxy correctly' do
      source = <<~ERB
        <%= form.lexxy_rich_text_area :content, **lexxy_embed_editor_options %>
      ERB

      expect(offences_in(source)).to eq(bare: 0, without_options: 0)
    end
  end
end
