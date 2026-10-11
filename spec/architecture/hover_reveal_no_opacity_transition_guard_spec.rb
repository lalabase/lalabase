# frozen_string_literal: true

require 'rails_helper'

# The hover-revealed action row is switched, never faded.
#
# Safari 26.6 (measured from a screen recording on 29.08.2026, 10 frames per
# second, one ink count per action row): a row the pointer crossed in under
# 100 ms went dark again the next frame; every row the pointer rested on for
# 200 ms or longer stayed lit after the pointer left, until something else
# repainted that part of the transcript. The dividing line is the 150 ms
# opacity transition. WebKit runs an opacity transition on its own compositing
# layer and drops that layer when the transition ends; Safari then fails to
# repaint the patch of the scrolling transcript underneath, and the last
# painted state (the row at full opacity) stays on screen. A pass shorter than
# the fade reverses the same still-live layer and never leaves stale pixels.
# Chromium and Playwright's WebKit do not show it; Safari proper renders the
# DOM in its GPU process, and that is where the repaint goes missing.
#
# So the reveal is a plain opacity switch: no transition on the node the class
# lands on, in the stylesheet that owns the rule and in the markup that carries
# the marker. Tailwind's `transition-opacity` or `transition-all` on the actions
# node would bring the fault straight back, which is why the markup is checked
# too, and only there: this is about the property being animated, not about a
# class chain, so no other class is pinned.
RSpec.describe 'hover-reveal actions are switched, not faded', type: :model do
  let(:stylesheet) { 'app/assets/stylesheets/components/hover_reveal.css' }
  let(:actions_marker) { 'data-hover-reveal-target="actions"' }

  def without_css_comments(css)
    css.gsub(%r{/\*.*?\*/}m, '')
  end

  it 'components/hover_reveal.css hides the actions with opacity and animates nothing' do
    css = without_css_comments(File.read(Rails.root.join(stylesheet)))

    expect(css).to include('opacity: 0'), 'the reveal must still be an opacity switch'
    expect(css).not_to match(/transition/i), <<~MSG
      #{stylesheet} declares a transition. The revealed node must not animate
      opacity: Safari 26.6 leaves the row painted at full opacity once the fade
      has ended (see the comment at the top of this spec).
    MSG
  end

  it 'no stylesheet animates a rule that targets the actions node' do
    offenders = Dir[Rails.root.join('app/assets/stylesheets/**/*.css')].flat_map do |file|
      css = without_css_comments(File.read(file))
      css.scan(/([^{}]*#{Regexp.escape(actions_marker)}[^{}]*)\{([^{}]*)\}/m)
         .select { |_selector, declarations| declarations.match?(/transition/i) }
         .map { |selector, _| "#{Pathname.new(file).relative_path_from(Rails.root)}: #{selector.strip}" }
    end

    expect(offenders).to be_empty, "rules with a transition on the actions node:\n#{offenders.join("\n")}"
  end

  it 'no template puts a transition utility on the actions node' do
    files = Dir[Rails.root.join('app/components/**/*.erb')] + Dir[Rails.root.join('app/views/**/*.erb')]

    offenders = files.flat_map do |file|
      File.read(file).scan(/<[^<>]*#{Regexp.escape(actions_marker)}[^<>]*>/m)
          .select { |tag| tag.match?(/class="[^"]*\btransition/) }
          .map { |tag| "#{Pathname.new(file).relative_path_from(Rails.root)}: #{tag.gsub(/\s+/, ' ')[0, 120]}" }
    end

    expect(offenders).to be_empty, "actions nodes carrying a transition class:\n#{offenders.join("\n")}"
  end
end
