# frozen_string_literal: true

require 'rails_helper'

# /appearance — 3-state picker (Automatic / Color / Off) for the per-user org color.
# Per-user (no Pundit). Whitelist against OrgColor (no free-form hex).
RSpec.describe 'Organisations::Appearances', type: :request do
  let(:organisation) { create(:organisation) }
  let(:role)         { create(:role, organisation: organisation, title: 'member') }
  let(:user)         { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  # 2nd active org -> ≥2 (otherwise the gate kicks in and "auto" would have nothing to color).
  let!(:second_org) do
    org = create(:organisation)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, role: create(:role, organisation: org), active: true)
    end
    org
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  # Is the radio with this value preselected (checked) in the rendered picker?
  def radio_checked?(value)
    response.body.include?(%(value="#{value}" class="sr-only peer" checked))
  end

  describe 'GET show' do
    it 'rendert alle drei Swatch-Typen (Automatisch / Farbe / Aus) via Partial' do
      get organisation_appearance_path(organisation)
      expect(response).to have_http_status(:success)
      expect(response.body).to include('value="auto"') # Automatic
      expect(response.body).to include("value=\"#{OrgColor::HEXES.first}\"") # a palette color
      expect(response.body).to include("value=\"#{OrgColor::OFF}\"") # Off
    end

    context 'Vorauswahl spiegelt den gespeicherten Zustand' do
      it 'waehlt die gesetzte Farbe vor (und NICHT Automatisch)' do
        user.org_colors.set(organisation, '#dbeafe')
        get organisation_appearance_path(organisation)
        expect(radio_checked?('#dbeafe')).to be(true)
        expect(radio_checked?('auto')).to be(false)
      end

      it 'waehlt "Aus" vor, wenn OFF gespeichert ist' do
        user.org_colors.set(organisation, OrgColor::OFF)
        get organisation_appearance_path(organisation)
        expect(radio_checked?(OrgColor::OFF)).to be(true)
      end

      it 'waehlt "Automatisch" vor, wenn nichts gespeichert ist' do
        user.org_colors.set(organisation, :auto) # remove entry -> nil
        get organisation_appearance_path(organisation)
        expect(radio_checked?('auto')).to be(true)
      end
    end
  end

  describe 'PATCH update' do
    it 'speichert eine konkrete Palette-Farbe und leitet weiter' do
      patch organisation_appearance_path(organisation), params: { org_color: '#dbeafe' }
      expect(response).to redirect_to(organisation_root_path(organisation))
      expect(user.reload.org_colors.setting_for(organisation)).to eq('#dbeafe')
    end

    context 'Whitelist-Positiv: JEDE Palette-Farbe wird akzeptiert und gespeichert' do
      # Hardcoded expected list instead of OrgColor::HEXES (lesson from the user split:
      # if someone shrinks the constant, the example would otherwise disappear instead of
      # going red). A removed palette color shows up here: the controller
      # then treats it as "auto" and does NOT store the sent hex.
      %w[#fef3c7 #d1fae5 #dbeafe #ede9fe #ffe4e6 #ffedd5 #cffafe #ecfccb].each do |hex|
        it "speichert #{hex}" do
          patch organisation_appearance_path(organisation), params: { org_color: hex }
          expect(user.reload.org_colors.setting_for(organisation)).to eq(hex)
        end
      end
    end

    it 'speichert OFF (aus)' do
      patch organisation_appearance_path(organisation), params: { org_color: OrgColor::OFF }
      expect(user.reload.org_colors.setting_for(organisation)).to eq(OrgColor::OFF)
    end

    it 'weist bei "auto" sofort eine Systemfarbe zu (kein farbloser Zwischenzustand)' do
      patch organisation_appearance_path(organisation), params: { org_color: 'auto' }
      stored = user.reload.org_colors.setting_for(organisation)
      expect(OrgColor.hex?(stored)).to be(true)
      expect(OrgColor::HEXES).to include(stored)
    end

    it 'lehnt einen NICHT-Palette-Hex ab (Whitelist) -> faellt auf Systemfarbe zurueck' do
      patch organisation_appearance_path(organisation), params: { org_color: '#123456' }
      stored = user.reload.org_colors.setting_for(organisation)
      expect(stored).not_to eq('#123456')
      expect(OrgColor::HEXES).to include(stored) # auto -> palette color
    end

    it 'behandelt Unsinn wie "auto" (sicher, kein Junk gespeichert)' do
      patch organisation_appearance_path(organisation), params: { org_color: 'banana' }
      expect(user.reload.org_colors.setting_for(organisation)).not_to eq('banana')
    end

    it 'kann von einer Farbe zurueck auf OFF wechseln' do
      patch organisation_appearance_path(organisation), params: { org_color: '#dbeafe' }
      patch organisation_appearance_path(organisation), params: { org_color: OrgColor::OFF }
      expect(user.reload.org_colors.setting_for(organisation)).to eq(OrgColor::OFF)
    end

    it 'setzt die Farbe NUR fuer die aktuelle Org, nicht fuer andere (Org-Scoping)' do
      before_other = user.org_colors.setting_for(second_org)
      patch organisation_appearance_path(organisation), params: { org_color: '#dbeafe' }
      expect(user.reload.org_colors.setting_for(organisation)).to eq('#dbeafe')
      expect(user.org_colors.setting_for(second_org)).to eq(before_other) # other org unchanged
    end
  end
end
