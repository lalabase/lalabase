# frozen_string_literal: true

require 'rails_helper'

# Operator name and legal pages in the instance admin (LegalIdentity). Every setting in this
# controller needs its own action, route and form block, and this one feeds the login page
# and the invitation consent of the whole instance.
RSpec.describe 'Admin legal identity settings' do
  let(:admin_beuser) { create(:beuser) } # factory: role 'admin', active
  let(:values) do
    {
      operator_name: 'Configured Operator',
      imprint_page_url: 'https://public.example/impressum',
      privacy_page_url: 'https://public.example/datenschutz',
      terms_page_url: 'https://public.example/agb'
    }
  end

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
  end

  describe 'as an admin' do
    before { log_in_admin }

    it 'renders the fields with the stored values and names the missing pages' do
      LegalIdentity.new(values.merge(terms_page_url: '')).save

      get admin_system_settings_path

      form = Nokogiri::HTML(response.body).at_css('#legal-identity-settings')
      expect(response).to have_http_status(:ok)
      expect(form.at_css('input[name="legal_identity[operator_name]"]')['value']).to eq('Configured Operator')
      expect(form.at_css('input[name="legal_identity[privacy_page_url]"]')['value']).to eq('https://public.example/datenschutz')
      expect(form.text).to include(I18n.t('views.shared.legal.terms'))
    end

    it 'stores the values and the login page shows them' do
      patch admin_update_legal_identity_path, params: { legal_identity: values }

      expect(response).to redirect_to(admin_system_settings_path)
      expect(LegalIdentity.load.terms_page_url).to eq('https://public.example/agb')

      get new_user_session_path
      legal = Nokogiri::HTML(response.body).at_css('.lp-auth-legal')
      expect(legal.text).to include('Configured Operator')
      expect(legal.css('a').map { |link| link['href'] }).to eq(values.values.drop(1))
    end

    it 'refuses a relative address, keeps the stored values and shows the error' do
      LegalIdentity.new(values).save

      patch admin_update_legal_identity_path,
            params: { legal_identity: values.merge(operator_name: 'Other Operator', imprint_page_url: '/impressum') }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('activemodel.errors.models.legal_identity.not_absolute_url'))
      expect(Nokogiri::HTML(response.body).at_css('input[name="legal_identity[imprint_page_url]"]')['value']).to eq('/impressum')
      expect(LegalIdentity.load.operator_name).to eq('Configured Operator')
    end

    it 'can clear a value again' do
      LegalIdentity.new(values).save

      patch admin_update_legal_identity_path, params: { legal_identity: values.merge(operator_name: '', privacy_page_url: '') }

      identity = LegalIdentity.load
      expect(identity.operator_name).to be_nil
      expect(identity.privacy_page_url).to be_nil
      expect(identity.terms_page_url).to eq('https://public.example/agb')
    end
  end

  it 'refuses anonymous requests' do
    patch admin_update_legal_identity_path, params: { legal_identity: values }

    expect(LegalIdentity.load.operator_name).to be_nil
  end
end
