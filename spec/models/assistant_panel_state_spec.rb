# frozen_string_literal: true

require 'rails_helper'

# S3a T4: the cookie is written by a line of JavaScript and read here on every
# request, so it is the one place in the panel where an arbitrary string from the
# browser turns into layout geometry. Everything unparseable has to become the
# closed default rather than reaching a view.
RSpec.describe AssistantPanelState do
  describe '.from_cookie' do
    it 'reads open state and width' do
      state = described_class.from_cookie('1:420')

      expect(state).to be_open
      expect(state.width).to eq(420)
    end

    it 'reads the closed state' do
      expect(described_class.from_cookie('0:420')).not_to be_open
    end

    # NOT %w[...]: inside it a "\n" is a literal backslash plus n, so the trailing
    # newline case -- the one that decides whether \z or $ was used -- would never
    # have been exercised.
    ['garbage', '2:420', '1:abc', '1:420;evil', ':420', '1:', '1:99999999', '<script>', "1:420\n"].each do |raw|
      it "falls back to the closed default for #{raw.inspect}" do
        state = described_class.from_cookie(raw)

        expect(state).not_to be_open
        expect(state.width).to eq(described_class::DEFAULT_WIDTH)
      end
    end

    it 'falls back for a missing cookie' do
      state = described_class.from_cookie(nil)

      expect(state).not_to be_open
      expect(state.width).to eq(described_class::DEFAULT_WIDTH)
    end

    # The bounds are the contract the Stimulus controller is handed as values.
    # A width outside them would be a panel that is either unusable or covers the
    # page it is supposed to accompany.
    it 'clamps a width below the minimum' do
      expect(described_class.from_cookie('1:100').width).to eq(described_class::MIN_WIDTH)
    end

    it 'clamps a width above the maximum' do
      expect(described_class.from_cookie('1:9999').width).to eq(described_class::MAX_WIDTH)
    end

    # The two above pass a width FAR outside the bounds, which survives every
    # off-by-one a clamp can suffer: MIN+1, MAX-1, > instead of >=, a swapped
    # pair. These are the three points where that shows.
    describe 'at the bounds themselves (n-1 / n / n+1)' do
      {
        (described_class::MIN_WIDTH - 1) => described_class::MIN_WIDTH,
        described_class::MIN_WIDTH => described_class::MIN_WIDTH,
        (described_class::MIN_WIDTH + 1) => described_class::MIN_WIDTH + 1,
        (described_class::MAX_WIDTH - 1) => described_class::MAX_WIDTH - 1,
        described_class::MAX_WIDTH => described_class::MAX_WIDTH,
        (described_class::MAX_WIDTH + 1) => described_class::MAX_WIDTH
      }.each do |given, expected|
        it "reads #{given} back as #{expected}" do
          expect(described_class.from_cookie("1:#{given}").width).to eq(expected)
        end
      end
    end

    # The pattern says \d{2,4}, and both ends of that range are a decision: one
    # digit is not a width anybody's browser wrote, five would be a number this
    # class has no business clamping into a plausible-looking panel.
    describe 'at the digit bounds of the pattern' do
      it 'refuses a one-digit width' do
        expect(described_class.from_cookie('1:9')).not_to be_open
      end

      it 'accepts a two-digit width and clamps it' do
        state = described_class.from_cookie('1:99')

        expect(state).to be_open
        expect(state.width).to eq(described_class::MIN_WIDTH)
      end

      it 'accepts a four-digit width' do
        expect(described_class.from_cookie('1:9999')).to be_open
      end

      it 'refuses a five-digit width' do
        expect(described_class.from_cookie('1:99999')).not_to be_open
      end
    end
  end

  # The bare instance IS the fallback every unparseable cookie lands on, so its
  # values are a contract rather than an accident. Asserted here directly, not
  # through from_cookie, so a change to the parser cannot mask a changed default.
  describe 'the defaults of a bare instance' do
    it 'is closed, default width, companion mode' do
      state = described_class.new

      expect(state).not_to be_open
      expect(state.width).to eq(described_class::DEFAULT_WIDTH)
      expect(state.mode).to eq(described_class::MODE_PANEL)
      expect(state).not_to be_full
    end

    # DEFAULT_WIDTH is handed to the Stimulus controller as a value AND used as
    # the fallback here. Outside the bounds it would be silently clamped in one
    # place and not in the other, which is the kind of disagreement that shows up
    # as a panel jumping on its first paint.
    it 'keeps DEFAULT_WIDTH inside the bounds it hands the controller' do
      expect(described_class::DEFAULT_WIDTH)
        .to be_between(described_class::MIN_WIDTH, described_class::MAX_WIDTH)
    end
  end

  describe '#content_offset' do
    it 'is the sidebar plus the panel, because the panel docks against the sidebar' do
      state = described_class.from_cookie('1:400')

      expect(state.content_offset).to eq(described_class::SIDEBAR_WIDTH + 400)
    end

    # In the full view the panel covers the page instead of accompanying it, so
    # there is nothing to push aside. Shifting anyway would move a page nobody
    # can see and leave a gap at the right edge once the user comes back down.
    it 'is nil in the full view, because nothing is standing next to anything' do
      expect(described_class.from_cookie('1:400:full').content_offset).to be_nil
    end
  end

  # S3c T2: the third state of the same chat (plan §4, L11). It rides in the
  # SAME cookie because it is the same piece of furniture -- and the reader must
  # keep understanding the cookies written before this field existed.
  describe 'the mode' do
    # Positive iteration over the CONSTANT, not over hand-written strings: a mode
    # dropped from the whitelist would otherwise fail closed to :panel in silence,
    # and a mode added to it would arrive with no coverage at all.
    described_class::MODES.each do |mode|
      it "reads the whitelisted mode #{mode.inspect} back" do
        expect(described_class.from_cookie("1:420:#{mode}").mode).to eq(mode)
      end
    end

    it 'defaults to the companion panel' do
      expect(described_class.from_cookie('1:400').mode).to eq('panel')
      expect(described_class.from_cookie('1:400')).not_to be_full
    end

    it 'reads the full view back' do
      state = described_class.from_cookie('1:400:full')

      expect(state.mode).to eq('full')
      expect(state).to be_full
    end

    # The field is appended, not inserted: every browser out there carries a
    # two-part cookie right now. If those stopped parsing, the panel would snap
    # shut for everyone on the next deploy -- a visible regression for a field
    # nobody asked for.
    it 'still reads a cookie written before the mode existed' do
      state = described_class.from_cookie('1:420')

      expect(state).to be_open
      expect(state.width).to eq(420)
      expect(state.mode).to eq('panel')
    end

    # Fail-closed like the rest of the parser: an unknown mode is the companion
    # panel, never the one that covers the page.
    it 'falls back to the panel for an unknown mode' do
      expect(described_class.from_cookie('1:420:kiosk').mode).to eq('panel')
      expect(described_class.from_cookie('1:420:').mode).to eq('panel')
    end

    it 'refuses to be full while closed (a closed panel has no state to show)' do
      expect(described_class.from_cookie('0:420:full')).not_to be_full
    end
  end
end
