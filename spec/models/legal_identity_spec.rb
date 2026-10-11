# frozen_string_literal: true

require 'rails_helper'

# The operator identity as instance admin settings. The pages that render it are covered in
# spec/requests/legal_identity_spec.rb, the admin form in
# spec/requests/admin/system_settings_legal_identity_spec.rb.
RSpec.describe LegalIdentity do
  let(:valid_values) do
    {
      operator_name: 'Configured Operator',
      imprint_page_url: 'https://public.example/impressum',
      privacy_page_url: 'https://public.example/datenschutz',
      terms_page_url: 'https://public.example/agb',
      # An operator who hosts the pages elsewhere leaves these empty; one who does
      # not writes them here and the instance serves them (LegalPagesController).
      imprint_body: "## Betreiber\n\nMusterfirma GmbH",
      privacy_body: 'Wir verarbeiten Daten wie folgt.',
      terms_body: 'Es gelten diese Bedingungen.'
    }
  end

  describe 'saving and loading' do
    it 'stores every value as its SystemSetting and loads it back' do
      expect(described_class.new(valid_values).save).to be(true)

      expect(SystemSetting.get(:legal_privacy_page_url)).to eq('https://public.example/datenschutz')
      loaded = described_class.load
      expect(described_class::ATTRIBUTES.index_with { |attribute| loaded.public_send(attribute) }).to eq(valid_values)
    end

    it 'strips values and treats blank ones as unset' do
      identity = described_class.new(operator_name: '  ', imprint_page_url: ' https://public.example/impressum ')

      expect(identity.operator_name).to be_nil
      expect(identity.url_for(:imprint)).to eq('https://public.example/impressum')
      expect(identity.url_for(:terms)).to be_nil
    end

    # Clearing a field is how an admin removes a link, so blank must reach the database.
    it 'clears a stored value' do
      described_class.new(valid_values).save
      described_class.new(valid_values.merge(terms_page_url: '')).save

      expect(described_class.load.terms_page_url).to be_nil
    end

    it 'has nothing before anyone saved' do
      identity = described_class.load

      expect(identity.operator_name).to be_nil
      expect(described_class::PAGES.map { |page| identity.url_for(page) }).to all(be_nil)
    end
  end

  describe '.current' do
    it 'reads the settings once and forgets them when they are saved' do
      described_class.new(valid_values).save
      expect(described_class.current.operator_name).to eq('Configured Operator')

      expect(SystemSetting).not_to receive(:where)
      described_class.current

      RSpec::Mocks.space.proxy_for(SystemSetting).reset
      described_class.new(valid_values.merge(operator_name: 'Renamed Operator')).save
      expect(described_class.current.operator_name).to eq('Renamed Operator')
    end
  end

  # A wrong value must not be stored: a relative path breaks the link in the data export
  # (rendered in a job, without a host), and a script URL runs on click.
  describe 'URL check' do
    {
      'a relative path' => '/datenschutz',
      'a host without scheme' => 'lalabase.com/datenschutz',
      'a script URL' => 'javascript:alert(1)',
      'a data URL' => 'data:text/html,hello',
      'an unparsable value' => 'https://exa mple.com/datenschutz'
    }.each do |description, url|
      it "refuses #{description} and stores nothing" do
        described_class.new(valid_values).save
        identity = described_class.new(valid_values.merge(operator_name: 'Other Operator', privacy_page_url: url))

        expect(identity.save).to be(false)
        expect(identity.errors.details[:privacy_page_url]).to eq([{ error: :not_absolute_url }])
        expect(described_class.load.operator_name).to eq('Configured Operator')
      end
    end

    it 'names the field in the message' do
      identity = described_class.new(terms_page_url: 'agb')
      identity.validate

      expect(identity.errors.full_messages).to eq([
                                                    "#{described_class.human_attribute_name(:terms_page_url)} " \
                                                    "#{I18n.t('activemodel.errors.models.legal_identity.not_absolute_url')}"
                                                  ])
    end

    it 'accepts absolute http and https URLs in any case' do
      identity = described_class.new(imprint_page_url: 'http://intranet.example/imprint', privacy_page_url: 'HTTPS://public.example/privacy')

      expect(identity).to be_valid
    end
  end

  it 'refuses an unknown page' do
    expect { described_class.new.url_for(:cookies) }.to raise_error(ArgumentError, /cookies/)
  end
end
