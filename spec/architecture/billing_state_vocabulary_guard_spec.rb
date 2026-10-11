# frozen_string_literal: true

require 'rails_helper'

# The source half of S1 (01.09.2026): the three billing states have ONE list and
# ONE way of turning into a word.
#
# The locale half lives in spec/locales/time_list_billing_words_spec.rb. This one
# guards the two habits that put the words in nine places to begin with:
#
#   1. a renderer writing out its own list of three, which is how the filter
#      pills and the overview table came to show the life cycle BACKWARDS while a
#      constant carrying the canonical order sat two directories away, and
#   2. a renderer reaching for t('...billing_status.<state>') directly, which is
#      one edit away from reaching for a key of its own instead.
#
# Both are greps rather than behaviour, on purpose: what is being pinned is that
# there is nothing to test twice.
RSpec.describe 'billing state vocabulary' do
  def app_sources
    Dir[Rails.root.join('app/**/*.{rb,erb}')].sort
  end

  # The DISPLAY layer only. A service has to name each state to build a WHERE
  # clause or an LLM tool description (TimeSessionFilterService is the documented
  # SQL twin of TimeSession.billing_bucket_for and says so); a view or component
  # naming all three is writing out the constant, which is how the order came to
  # run backwards in two places at once.
  def rendering_sources
    Dir[Rails.root.join('app/{views,components}/**/*.{rb,erb}')].sort
  end

  # Locals, not constants: RuboCop refuses constants defined inside a block, and
  # the locale guard next door does the same.
  #
  # The bare states as a Ruby/ERB list of three, in either order. Deliberately
  # narrow: it looks for the three keys side by side, which is what a copy of the
  # constant looks like, not for a file that happens to mention one of them.
  triple = /
    (?:['"]?without_billing['"]?.{0,80}?['"]?in_billing['"]?.{0,80}?['"]?billed['"]?)
    |
    (?:['"]?billed['"]?.{0,80}?['"]?in_billing['"]?.{0,80}?['"]?without_billing['"]?)
  /xm

  # The two components that map the states to something that is NOT a word, and
  # therefore cannot iterate a list of keys alone. Both are pinned below against
  # the constant's SET, so a fourth bucket still cannot slip past them.
  allowed_triples = [
    # colour tokens plus the drawing order of the share bar: deliberately the
    # reverse of the column order, because a progress bar fills with what is done
    'app/components/neo_time_share_bar_component.rb',
    # accent colours per stage on the overview widget
    'app/components/overview/billing_overview_component.rb'
  ].freeze

  it 'has no second list of the three states in a view or component' do
    offenders = rendering_sources.filter_map do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root).to_s
      next if allowed_triples.include?(relative)

      relative if File.read(path).match?(triple)
    end

    expect(offenders).to be_empty,
                         'These files write out the three billing states themselves. Iterate ' \
                         "TimeSession::BILLING_STATUS_FILTERS instead:\n  #{offenders.join("\n  ")}"
  end

  # The share bar keeps its own ORDER (see above) but must never keep its own
  # SET: a bucket added to the constant and forgotten here would silently drop
  # out of every bar and out of every bar's label.
  it 'draws the share bar from the same set of buckets as the constant' do
    expect(NeoTimeShareBarComponent::SEGMENTS.keys).to match_array(TimeSession::BILLING_STATUS_FILTERS)
    expect(NeoTimeShareBarComponent::DOT_FILLS.keys).to match_array(TimeSession::BILLING_STATUS_FILTERS)
  end

  # The overview widget's whitelist IS the constant, not a copy that agrees with
  # it today. Identity, not equality: a re-declared literal would pass ==.
  it 'points the overview widget stage keys at the constant itself' do
    expect(Overview::BillingOverviewComponent::STAGE_KEYS).to be(TimeSession::BILLING_STATUS_FILTERS)
  end

  # The constant's order is the life cycle. The whole point of F2 was that this
  # was written down in one place and followed in none.
  it 'keeps the constant in life-cycle order' do
    expect(TimeSession::BILLING_STATUS_FILTERS).to eq(%w[without_billing in_billing billed])
  end

  # One seam from a state to a word. TimeSessionsHelper#time_billing_state_label
  # is it; everything else asks it.
  it 'renders the state words only through the label helper' do
    scope = 'views.time_sessions.billing_status'
    direct = app_sources.filter_map do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root).to_s
      next if relative == 'app/helpers/time_sessions_helper.rb'

      body = File.read(path)
      # The phrases around the words (partial, hidden_note, without_subject, ...)
      # are sentences of the time list, not state names, and stay where they are.
      states = (TimeSession::BILLING_STATUS_FILTERS + %w[mixed]).join('|')
      relative if body.match?(/#{Regexp.escape(scope)}\.(?:#{states})\b/) ||
                  body.match?(/#{Regexp.escape(scope)}\.\#\{/)
    end

    expect(direct).to be_empty,
                      'These files translate a billing state themselves. Call ' \
                      "time_billing_state_label(state) instead:\n  #{direct.join("\n  ")}"
  end
end
