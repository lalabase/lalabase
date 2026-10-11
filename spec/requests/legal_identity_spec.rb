# frozen_string_literal: true

require 'rails_helper'

# The operator identity on the core pages that render it. The values come from the instance
# admin settings (LegalIdentity, spec/models/legal_identity_spec.rb). The language is chosen
# with ?locale= (remembered for the next page), never through a public page: those leave the
# core in step W6 of the website split.
module LegalIdentityRequestSpec
  CONFIGURED = {
    operator_name: 'Configured Operator',
    imprint_page_url: 'https://public.example/impressum',
    privacy_page_url: 'https://public.example/datenschutz',
    terms_page_url: 'https://public.example/agb'
  }.freeze
end

RSpec.describe 'Legal identity on core pages', type: :request do
  def page
    Nokogiri::HTML(response.body)
  end

  def legal_links(css)
    page.css("#{css} a").map { |link| [link.text.strip, link['href']] }
  end

  context 'with an operator name and legal URLs', legal_identity: LegalIdentityRequestSpec::CONFIGURED do
    # The labels are the ones the login showed before the operator identity became
    # configurable (static.footer.*): W1 promised no visible change.
    it 'shows the configured copyright and the German legal links on the login page' do
      get new_user_session_path

      expect(page.at_css('.lp-auth-legal').text).to include("© #{Date.current.year} Configured Operator")
      expect(legal_links('.lp-auth-legal')).to eq([
                                                    ['Impressum', 'https://public.example/impressum'],
                                                    ['Datenschutz', 'https://public.example/datenschutz'],
                                                    ['AGB', 'https://public.example/agb']
                                                  ])
    end

    # One address per page: the website behind it picks the language.
    it 'uses the English labels with the same addresses for ?locale=en' do
      get new_user_session_path(locale: 'en')

      expect(legal_links('.lp-auth-legal')).to eq([
                                                    ['Imprint', 'https://public.example/impressum'],
                                                    ['Privacy Policy', 'https://public.example/datenschutz'],
                                                    ['Terms', 'https://public.example/agb']
                                                  ])
    end

    # The sessionless layout still carries the admin login and the instance
    # legal pages; the Devise pages moved to application_auth on 20.09.2026.
    it 'separates the sessionless footer links evenly' do
      get admin_log_in_path

      footer = page.at_css('footer p')
      expect(footer.text.squish).to eq("© #{Date.current.year} Configured Operator | Impressum | Datenschutz | AGB")
    end
  end

  context 'without legal identity', legal_identity: {} do
    I18n.available_locales.each do |locale|
      it "shows the product credit in #{locale} on the auth pages and the sessionless layout" do
        get new_user_session_path(locale: locale)
        expect(response).to have_http_status(:ok)
        expect(page.at_css('html')['lang']).to eq(locale.to_s)
        expect(page.at_css('.lp-auth-legal').text).to include('powered by Lalabase')

        allow(SystemSetting).to receive(:allow_registration?).and_return(false)
        get new_user_registration_path
        expect(page.at_css('html')['lang']).to eq(locale.to_s)
        expect(page.at_css('.lp-auth-legal').text).to include('powered by Lalabase')

        get new_user_password_path
        expect(page.at_css('html')['lang']).to eq(locale.to_s)
        expect(page.at_css('.lp-auth-legal').text).to include('powered by Lalabase')

        get admin_log_in_path
        expect(page.at_css('footer').text.squish).to eq('powered by Lalabase')
      end
    end

    it 'renders no optional legal links' do
      get new_user_session_path

      expect(page.css('.lp-auth-legal a')).to be_empty
    end
  end
end
