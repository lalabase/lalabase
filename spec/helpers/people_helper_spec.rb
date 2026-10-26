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

  it 'counts late yesterday evening as yesterday, not as hours ago' do
    expect(I18n.with_locale(:de) { helper.last_contact_age(Time.zone.local(2026, 10, 25, 23, 50)) }).to eq('gestern')
  end
end
