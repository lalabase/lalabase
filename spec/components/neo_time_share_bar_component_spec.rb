# frozen_string_literal: true

require 'rails_helper'

# What: NeoTimeShareBarComponent, the share bar of the Projektzeiten table.
# Type: Component spec.
# Why:  T7 of doc/projektzeiten_tabelle_plan.md. The bar is the ONE owner of the
#       three time-* colour tokens, drawn by the table row, by the booking under
#       an opened row and by the mobile card. A second colour sneaking in here
#       means the same state looks different on two screens; a hard-coded hex
#       means it looks wrong in the dark theme, where two of the three tokens
#       change value.
RSpec.describe NeoTimeShareBarComponent, type: :component do
  # render_inline hands back the fragment; Capybara's `page` has no #css.
  def bar(shares, **opts)
    render_inline(described_class.new(shares: shares, **opts))
  end

  def widths(shares, **opts)
    bar(shares, **opts).css('span[style]').map { |node| node['style'][/(\d+)%/, 1].to_i }
  end

  describe 'the proportions' do
    it 'draws one segment per filled bucket, in the order done, on its way, untouched' do
      rendered = bar({ 'billed' => 60, 'in_billing' => 60, 'without_billing' => 120 })

      expect(rendered.css('span[style]').map { |node| node['class'] })
        .to eq(['block h-full bg-time-billed', 'block h-full bg-time-in-billing', 'block h-full bg-transparent'])
      expect(widths({ 'billed' => 60, 'in_billing' => 60, 'without_billing' => 120 })).to eq([25, 25, 50])
    end

    # Mutation: round every segment on its own and 1/3 + 1/3 + 1/3 leaves a
    # one-per-cent gap of bare track at the end of a full bar.
    it 'always adds up to a hundred, whatever the rounding does' do
      expect(widths({ 'billed' => 10, 'in_billing' => 10, 'without_billing' => 10 }).sum).to eq(100)
      expect(widths({ 'billed' => 1, 'in_billing' => 0, 'without_billing' => 999 }).sum).to eq(100)
    end

    it 'leaves out a bucket that holds nothing' do
      expect(widths({ 'billed' => 0, 'in_billing' => 30, 'without_billing' => 90 })).to eq([25, 75])
    end

    it 'is an empty track when nothing is booked, without dividing by zero' do
      expect { bar({}) }.not_to raise_error
      rendered = bar({})
      expect(rendered.css('span[style]')).to be_empty
      expect(rendered.css('span').first['class']).to include('border-stroke/70')
    end
  end

  describe 'what it says to a screen reader' do
    it 'names only the filled buckets, with their minutes' do
      rendered = bar({ 'billed' => 220, 'in_billing' => 60, 'without_billing' => 0 })

      # ⚠️ The three words have ONE owner (views.time_sessions.billing_status, S1),
      # and they have changed once. Read from it, or this file fails for a change
      # that has nothing to do with the bar.
      expect(rendered.css('span').first['aria-label'])
        .to eq("#{I18n.t('views.time_sessions.billing_status.billed')}: 03:40 · #{I18n.t('views.time_sessions.billing_status.in_billing')}: 01:00")
      expect(rendered.css('span').first['title'])
        .to eq("#{I18n.t('views.time_sessions.billing_status.billed')}: 03:40 · #{I18n.t('views.time_sessions.billing_status.in_billing')}: 01:00")
    end

    it 'says the same thing in English' do
      I18n.with_locale(:en) do
        rendered = bar({ 'billed' => 220, 'without_billing' => 120 })

        expect(rendered.css('span').first['aria-label'])
          .to eq("#{I18n.t('views.time_sessions.billing_status.billed')}: 03:40 · #{I18n.t('views.time_sessions.billing_status.without_billing')}: 02:00")
      end
    end

    # An image with an empty description is worse than no image role at all.
    it 'is decoration when there is nothing to describe' do
      rendered = bar({ 'billed' => 0 })

      expect(rendered.css('span').first['role']).to be_nil
      expect(rendered.css('span').first['aria-hidden']).to eq('true')
    end
  end

  # A bar claims a division. Where there is none it is a measurement that measures
  # nothing, and a screen full of them is what made the list hard to read.
  describe 'one state versus several' do
    def dots(shares, **opts)
      bar(shares, **opts).css('span span')
    end

    it 'is a dot when a single bucket holds everything' do
      rendered = bar({ 'billed' => 0, 'in_billing' => 0, 'without_billing' => 90 })

      expect(rendered.css('span[style]')).to be_empty
      expect(rendered.css('span span').size).to eq(1)
      expect(rendered.css('span span').first['class']).to include('h-2.5', 'w-2.5', 'rounded-full')
    end

    it 'carries the state in the dot, painted the same as a segment would be' do
      expect(dots({ 'billed' => 60 }).first['class']).to include('bg-time-billed')
      expect(dots({ 'in_billing' => 60 }).first['class']).to include('bg-time-in-billing')
    end

    # "Nothing invoiced yet" is an outline on the page's own ground: empty to the
    # eye, but opaque, so a dot in front of it can cover it.
    it 'fills an un-billed dot with the surface rather than nothing' do
      expect(dots({ 'without_billing' => 60 }).first['class']).to include('bg-surface')
    end

    it 'is a bar again as soon as a second bucket holds something' do
      rendered = bar({ 'billed' => 60, 'without_billing' => 30 })

      expect(rendered.css('span').first['class']).to include('w-6')
      expect(rendered.css('span[style]').size).to eq(2)
    end

    it 'still names the minutes, dot or bar' do
      expect(bar({ 'billed' => 60 }).css('span').first['aria-label'])
        .to eq("#{I18n.t('views.time_sessions.billing_status.billed')}: 01:00")
    end

    it 'shrinks the dot with the thin size, so a booking is smaller than its row' do
      expect(dots({ 'billed' => 60 }, size: :thin).first['class']).to include('h-2', 'w-2')
    end
  end

  describe 'the colours' do
    # The reason this component exists. Mutation: write bg-amber-600 or a hex
    # anywhere in the template, and the two themes that redefine these tokens
    # stop matching the third.
    it 'paints with the two time tokens, and leaves the empty part unpainted' do
      rendered = bar({ 'billed' => 10, 'in_billing' => 10, 'without_billing' => 10 })

      backgrounds = rendered.css('[class]').flat_map { |node| node['class'].split }.grep(/\Abg-/).uniq
      expect(backgrounds).to match_array(%w[bg-transparent bg-time-billed bg-time-in-billing])
      expect(rendered.to_html).not_to include('#')
    end

    # The first version painted the empty part with cream-300, which is a light
    # sand in Light and Dark and "edge dark gray" in POP -- the theme the app
    # renders by default. The emptiest state came out almost black. It is not
    # painted at all now, so no token can do that to it again.
    it 'never paints the untouched part' do
      rendered = bar({ 'billed' => 10, 'in_billing' => 0, 'without_billing' => 60 })

      painted = rendered.css('span[style]').map { |node| node['class'] }
      expect(painted).to eq(['block h-full bg-time-billed', 'block h-full bg-transparent'])
    end
  end

  describe 'the two sizes' do
    it 'keeps one width, so the columns line up whichever is drawn' do
      mixed = { 'billed' => 10, 'without_billing' => 10 }
      row = bar(mixed, size: :row).css('span').first['class']
      thin = bar(mixed, size: :thin).css('span').first['class']

      expect(row).to include('h-2', 'w-6')
      expect(thin).to include('h-[5px]', 'w-5')
    end

    it 'falls back to the row size rather than rendering without one' do
      rendered = bar({ 'billed' => 10, 'without_billing' => 10 }, size: :nonsense)

      expect(rendered.css('span').first['class']).to include('h-2')
    end
  end
end
