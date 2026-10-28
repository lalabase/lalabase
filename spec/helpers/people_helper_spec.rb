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

  # A member row with only a salutation has details: no "add details" hint.
  describe '#person_bare?' do
    it 'counts a salutation as a detail' do
      ActsAsTenant.with_tenant(create(:organisation)) do
        expect(helper.person_bare?(Person.new(name: 'Müller'))).to be(true)
        expect(helper.person_bare?(Person.new(name: 'Müller', salutation: 'Frau'))).to be(false)
      end
    end

    it 'counts an additional detail as a detail' do
      ActsAsTenant.with_tenant(create(:organisation)) do
        person = Person.new(name: 'Müller', additional_details: [{ 'kind' => 'text', 'label' => '', 'value' => 'x' }])

        expect(helper.person_bare?(person)).to be(false)
      end
    end
  end

  # The lane lines of the additional details, after the phone, in stored
  # order: the kind decides the link and the format.
  describe '#person_fields with additional details' do
    before { ActsAsTenant.current_tenant = create(:organisation) }
    after { ActsAsTenant.current_tenant = nil }

    def fields_for(*details, phone: '+49 30 1234567')
      person = Person.new(name: 'Müller', phone: phone, additional_details: details)
      helper.person_fields(person, nil)
    end

    def detail(kind, value, label: '')
      { 'kind' => kind, 'label' => label, 'value' => value }
    end

    it 'puts them after the phone, in their order, labelled' do
      fields = fields_for(detail('phone', '+49 30 1234568', label: 'Fax'), detail('text', 'nur vormittags', label: 'Erreichbar'))

      expect(fields.pluck(:label)).to eq([Person.human_attribute_name(:phone), 'Fax', 'Erreichbar'])
    end

    it 'links a phone through tel:, an email through mailto:, a url to a new tab' do
      phone, email, url = fields_for(detail('phone', '+49 (170) 123-4567', label: 'Mobil'),
                                     detail('email', 'erika@example.com'),
                                     detail('url', 'https://example.com'), phone: nil)

      expect(phone).to include(href: 'tel:+491701234567', mono: true, value: '+49 (170) 123-4567', action: 'Mobil')
      expect(email).to include(href: 'mailto:erika@example.com', value: 'erika@example.com')
      expect(url).to include(href: 'https://example.com', external: true)
    end

    it 'names the kind when the label is empty' do
      fields = I18n.with_locale(:de) { fields_for(detail('phone', '+49 30 1'), phone: nil) }

      expect(fields.first[:label]).to eq('Telefon')
    end

    it 'formats a date in the reader\'s language' do
      german = I18n.with_locale(:de) { fields_for(detail('date', '1980-02-29'), phone: nil) }.first
      english = I18n.with_locale(:en) { fields_for(detail('date', '1980-02-29'), phone: nil) }.first

      expect(german[:value]).to eq(I18n.l(Date.new(1980, 2, 29), format: :long, locale: :de))
      expect(english[:value]).to eq(I18n.l(Date.new(1980, 2, 29), format: :long, locale: :en))
      expect(german[:value]).to include('Februar')
    end

    it 'keeps the lines of an address and escapes them' do
      value = fields_for(detail('address', "<b>Haupt</b>straße 5\n12345 Köln"), phone: nil).first[:value]

      expect(value).to eq('&lt;b&gt;Haupt&lt;/b&gt;straße 5<br>12345 Köln')
    end

    it 'never links a url written around the validation' do
      field = fields_for(detail('url', 'javascript:alert(1)'), phone: nil).first

      expect(field[:href]).to be_nil
      expect(field[:value]).to eq('javascript:alert(1)')
    end

    # Review round 1, finding 4: an entry written around the validation.
    it 'names an unknown kind as stored and gives it a plain text field in the form' do
      field = fields_for(detail('fax', '+49 30 1'), phone: nil).first

      expect(field).to eq(label: 'fax', value: '+49 30 1')
      expect(helper.person_detail_field('fax')).to eq(helper.person_detail_field('text'))
      expect(helper.person_detail_field('fax')[:input]).to eq('text')
    end

    # Review round 1, finding 8: the fixed phone links through the same rule.
    it 'links the fixed phone through PersonDetail, and not at all without digits' do
      expect(fields_for(phone: '+49 (30) 123-4567').first[:href]).to eq('tel:+49301234567')
      expect(fields_for(phone: 'nur Zentrale').first[:href]).to be_nil
    end

    # Review round 3, finding 3: the fixed email is the account's for a member,
    # checked by Devise only; it keeps its link as before.
    it 'links the fixed email as it is, also one only Devise accepts' do
      expect(helper.person_fields(Person.new(name: 'M', email: 'jörg@example.com'), nil).first[:href])
        .to eq('mailto:jörg@example.com')
    end

    it 'shows no line for a person without details' do
      expect(fields_for(phone: nil)).to eq([])
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
