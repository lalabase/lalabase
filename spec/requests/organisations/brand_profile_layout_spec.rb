# frozen_string_literal: true

require 'rails_helper'

# Org recognition color — layout wiring (M2'). Verifies end-to-end that
# current_user + @current_organisation flow via brand_style_for into the inline `--brand`
# on the <html>: set with >=2 orgs (with color), absent with 1 org / OFF.
# (The visible mark chip/line is added in M3'; here only the CSS variable.)
RSpec.describe 'Org recognition colour (layout wiring)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:role)         { create(:role, organisation: organisation, title: 'member') }
  let(:user)         { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  # Second active org -> over the threshold (hook colors automatically).
  def join_second_org
    second = create(:organisation)
    ActsAsTenant.with_tenant(second) do
      create(:membership, user: user, organisation: second, role: create(:role, organisation: second), active: true)
    end
    second
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  context 'User mit >=2 Orgs (auto-gefaerbt)' do
    before { join_second_org }

    it 'rendert das Inline --brand am <html>' do
      get organisation_appearance_path(organisation)
      expect(response.body).to match(/<html[^>]*style="--brand: \d{1,3} \d{1,3} \d{1,3};"/)
    end

    it 'rendert die linke Kantenlinie (border-s-brand) bei >=2 Orgs' do
      get organisation_appearance_path(organisation)
      expect(response.body).to include('border-s-brand')
    end

    it 'rendert KEIN --brand UND keine Kantenlinie, wenn die aktuelle Org auf OFF steht' do
      user.org_colors.set(organisation, OrgColor::OFF)
      get organisation_appearance_path(organisation)
      expect(response.body).not_to include('--brand:')
      expect(response.body).not_to include('border-s-brand')
    end

    it 'leakt den OFF-Sentinel nie als CSS-Wert an der Sidebar-Flaeche' do
      # The resolver-bypass mutant (setting_for instead of effective_color on the aside) would
      # render OFF as `background-color: off` inline — a direct, diagnostic
      # pin in addition to the border-s-brand assert above (which catches the same mutant
      # only indirectly, because 'off' is truthy).
      user.org_colors.set(organisation, OrgColor::OFF)
      get organisation_appearance_path(organisation)
      expect(response.body).not_to include('background-color: off')
    end

    it 'spiegelt eine konkret gesetzte Farbe EXAKT — als --brand (Chip) UND als Sidebar-Flaeche' do
      # #dbeafe -> 0xdb=219, 0xea=234, 0xfe=254. Two separate render paths for the same color:
      # the chip via the --brand variable (rgb channels), the sidebar SURFACE via inline hex.
      # Both must carry the exact color -> a fault in ANY link breaks here.
      user.org_colors.set(organisation, '#dbeafe')
      get organisation_appearance_path(organisation)
      expect(response.body).to include('--brand: 219 234 254;') # chip (variable on the <html>)
      # Sidebar SURFACE: anchored on the <aside> tag — NOT just "#dbeafe somewhere", because the
      # appearance page renders the sidebar color preset swatches (sky == #dbeafe) as its own
      # background-color divs -> an unanchored match would be a false positive.
      expect(response.body).to match(/<aside\b[^>]*style="background-color: #dbeafe;"/)
    end
  end

  # The application carries the brand mark of the public pages, ONE partial
  # (user, 10.09.2026): the wordmark is "alabase" as on the start page, not the
  # "alaBase" the sidebar spelled for itself, and the chip is the partial's with
  # bg-brand in place of the public lime-300.
  it 'zeigt in der Seitenleiste dieselbe Marke wie die oeffentlichen Seiten, die Kachel auf bg-brand' do
    get organisation_root_path(organisation_id: organisation.id)

    sidebar = Nokogiri::HTML(response.body).at_css('.sidebar')
    wordmark = sidebar.at_css('span.inline')
    expect(wordmark.text).to eq('alabase')
    expect(response.body).not_to include('alaBase')
    chip = wordmark.previous_element
    expect(chip.text.strip).to eq('L')
    expect(chip['class']).to include('bg-brand', 'shadow-[3px_3px_0_0_#000000]', 'border-black', 'text-black')
    public_chip = Nokogiri::HTML(ApplicationController.render(partial: 'shared/brand_mark')).at_css('div')
    expect(chip['class'].split).to match_array(public_chip['class'].split.map { |c| c == 'bg-lime-300' ? 'bg-brand' : c })
  end

  context 'User mit nur einer Org' do
    it 'rendert KEIN --brand (kein Unterscheidungsbedarf) -> :root-Default greift' do
      get organisation_appearance_path(organisation)
      expect(response.body).not_to include('--brand:')
    end

    it 'rendert KEINE Kantenlinie (gegated) -> pixelgleich' do
      get organisation_appearance_path(organisation)
      expect(response.body).not_to include('border-s-brand')
    end

    it 'rendert den Logo-Chip dennoch auf bg-brand (Default --brand = lime-300 -> die Kachel der Startseite)' do
      # The chip is NOT gated: without an effective color the :root default (lime-300, the
      # public brand mark's chip since 10.09.2026) applies, so the chip is the public one,
      # just via the variable.
      get organisation_appearance_path(organisation)
      expect(response.body).to include('bg-brand')
    end

    it 'behaelt die bg-cream-200-Grundflaeche der Sidebar (Fallback gepinnt)' do
      # Without an effective color, the class is the only light background of the
      # sidebar — if the `unless org_brand` fallback in the layout is dropped, it becomes
      # transparent (silent visual regression). Anchored on the <aside> tag, because
      # bg-cream-100 also hangs on body/main. The opposite direction (class despite
      # inline color) DELIBERATELY left unpinned: the inline style wins -> equivalent.
      get organisation_appearance_path(organisation)
      expect(response.body).to match(/<aside\b[^>]*bg-cream-200/)
    end
  end
end
