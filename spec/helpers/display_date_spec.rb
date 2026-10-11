# frozen_string_literal: true

require 'rails_helper'

# What: a DATE in the reader's own format, without a clock.
# Type: helper spec.
# Why: display_time uses the area's whole format, and most areas carry %H:%M.
#   On a Date that reads "00:00" - a time nobody entered, printed after a value
#   that has none (user, 07.09.2026: the due date in the list). Hiding it in CSS
#   would have left the lie in the markup and in every other place the value is
#   read out.
RSpec.describe ApplicationHelper, type: :helper do
  describe '#display_date' do
    let(:user) { build_stubbed(:user) }

    def formatted(format)
      allow(user).to receive(:date_strftime_format).with('ticket_list_large').and_return(format)
      helper.display_date(Date.new(2026, 6, 28), area: 'ticket_list_large', user: user)
    end

    it 'drops the clock the area format carries' do
      expect(formatted('%d.%m.%Y %H:%M')).to eq('28.06.2026')
    end

    it 'drops it with seconds too' do
      expect(formatted('%d.%m.%Y %H:%M:%S')).to eq('28.06.2026')
    end

    it 'keeps a format that never had one, in the order the reader chose' do
      expect(formatted('%Y-%m-%d')).to eq('2026-06-28')
    end

    it 'is empty for no date at all, not "00:00" and not a stray dash' do
      expect(helper.display_date(nil, area: 'ticket_list_large', user: user)).to eq('')
    end

    # A reader who has chosen the relative form ("vor 3 Tagen") has no absolute
    # format at all; a date still has to be written somehow.
    it 'falls back to the locale format when the reader has none' do
      allow(user).to receive(:date_strftime_format).and_return(nil)
      expect(helper.display_date(Date.new(2026, 6, 28), area: 'ticket_list_large', user: user)).to be_present
    end
  end
end
