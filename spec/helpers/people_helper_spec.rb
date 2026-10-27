# frozen_string_literal: true

require 'rails_helper'

# The age of a last contact in the list (S2a): calendar days, not hours, in
# both languages, at the edges of every step.
RSpec.describe PeopleHelper, type: :helper do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.local(2026, 10, 26, 9, 0)) { example.run } }

  {
    0 => %w[heute today],
    1 => %w[gestern yesterday],
    2 => ['vor 2 Tagen', '2 days ago'],
    6 => ['vor 6 Tagen', '6 days ago'],
    7 => ['vor 1 Woche', '1 week ago'],
    13 => ['vor 1 Woche', '1 week ago'],
    14 => ['vor 2 Wochen', '2 weeks ago'],
    29 => ['vor 4 Wochen', '4 weeks ago'],
    30 => ['vor 1 Monat', '1 month ago'],
    59 => ['vor 1 Monat', '1 month ago'],
    60 => ['vor 2 Monaten', '2 months ago'],
    364 => ['vor 12 Monaten', '12 months ago'],
    365 => ['vor 1 Jahr', '1 year ago'],
    800 => ['vor 2 Jahren', '2 years ago']
  }.each do |days, (german, english)|
    it "says #{german} / #{english} for #{days} days" do
      at = days.days.ago.change(hour: 23)

      expect(I18n.with_locale(:de) { helper.last_contact_age(at) }).to eq(german)
      expect(I18n.with_locale(:en) { helper.last_contact_age(at) }).to eq(english)
    end
  end

  # Review round 1: the date of the last meeting names its year when it is
  # not this year.
  describe '#last_contact_text' do
    def meeting_contact(at)
      People::Contacts::LastContact.new(at: at, kind: :meeting, meeting_title: 'Kick-off')
    end

    it 'leaves the year out for this year' do
      expect(I18n.with_locale(:de) { helper.last_contact_text(meeting_contact(Time.zone.local(2026, 10, 3, 10))) })
        .to eq('Letztes Meeting: Kick-off, 03.10.')
    end

    it 'names the year of an older meeting' do
      expect(I18n.with_locale(:de) { helper.last_contact_text(meeting_contact(Time.zone.local(2024, 10, 3, 10))) })
        .to eq('Letztes Meeting: Kick-off, 03.10.2024')
    end
  end

  it 'counts late yesterday evening as yesterday, not as hours ago' do
    expect(I18n.with_locale(:de) { helper.last_contact_age(Time.zone.local(2026, 10, 25, 23, 50)) }).to eq('gestern')
  end
end
