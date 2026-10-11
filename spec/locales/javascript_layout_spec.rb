# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'JavaScript locale values in the application layout', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:admin_role, organisation: organisation))
    end
    sign_in user
  end

  def locale_script
    expect(response).to have_http_status(:ok)
    script = Nokogiri::HTML(response.body).css('script').find { |node| node.text.include?('window.translations =') }
    expect(script).to be_present
    script.text
  end

  %i[de en].each do |locale|
    it "exposes the complete #{locale} translations as an object and the locale as a string" do
      user.update!(language_preference: locale.to_s)
      get organisation_root_path(organisation_id: organisation.id)

      script = locale_script
      translations = JSON.parse(script[/window\.translations = (.*);$/, 1])
      expect(translations).to eq('stimulus' => I18n.t('stimulus', locale: locale).deep_stringify_keys)
      expect(JSON.parse(script[/window\.locale = (.*);$/, 1])).to eq(locale.to_s)
    end
  end

  it 'preserves special characters without letting translations terminate the script element' do
    label = "</script><script id='translation-probe'>alert(1)</script> & \"quoted\" \u2028\u2029"
    allow(I18n).to receive(:t).and_call_original
    allow(I18n).to receive(:t).with('stimulus').and_return({ label: label })

    get organisation_root_path(organisation_id: organisation.id, locale: :de)

    translations = JSON.parse(locale_script[/window\.translations = (.*);$/, 1])
    expect(translations).to eq('stimulus' => { 'label' => label })
    expect(Nokogiri::HTML(response.body).at_css('#translation-probe')).to be_nil
  end
end
