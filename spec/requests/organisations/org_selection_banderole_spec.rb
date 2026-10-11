# frozen_string_literal: true

require 'rails_helper'

# Org recognition color — banderole on the org selection page (M4'). Each tile shows the
# org color in the avatar box (linking color <-> org). Source = resolver: only from
# >=2 orgs, OFF/1-org -> no coloring (pixel-identical). Full chain set->resolver->view.
RSpec.describe 'Org recognition colour (selection page)', type: :request do
  let(:user) { create(:user) }

  def join_org(active: true)
    org = create(:organisation)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, role: create(:role, organisation: org), active: active)
    end
    org
  end

  before { sign_in user }

  context 'User mit >=2 Orgs' do
    it 'faerbt das Avatar-Kaestchen mit der konkreten Org-Farbe (Voll-Kette)' do
      org_a = join_org
      join_org
      user.org_colors.set(org_a, '#dbeafe')
      get select_organisation_path
      expect(response.body).to include('background-color: #dbeafe;')
    end

    it 'faerbt eine auf OFF gestellte Org NICHT (nur die andere Kachel ist getoent)' do
      org_a = join_org
      join_org # auto-colored
      user.org_colors.set(org_a, OrgColor::OFF)
      get select_organisation_path
      expect(response.body).not_to include('background-color: off') # no sentinel leak
      # Proof that org_a is REALLY uncolored: exactly ONE toned tile (the other one),
      # not two. (On the selection page @current_organisation is nil -> the sidebar colors
      # nothing -> the only inline color source is the avatar boxes.)
      expect(response.body.scan('background-color: #').size).to eq(1)
    end

    it 'jede Kachel traegt IHRE Org-Farbe (beide Hexe erscheinen)' do
      # A tile-color mix-up (e.g. effective_color(@organisations.first) instead of
      # (org) in the loop) would color both tiles the same. Pinned order-
      # independently: BOTH explicitly set colors must be in the body.
      org_a = join_org
      org_b = join_org
      user.org_colors.set(org_a, '#dbeafe')
      user.org_colors.set(org_b, '#cffafe')
      get select_organisation_path
      expect(response.body).to include('background-color: #dbeafe;')
      expect(response.body).to include('background-color: #cffafe;')
    end
  end

  context 'User mit nur einer Org' do
    it 'faerbt nichts (kein Unterscheidungsbedarf) -> Avatar bleibt cream-200' do
      join_org
      get select_organisation_path
      expect(response.body).not_to include('background-color: #')
    end

    it 'behaelt den bg-cream-200-Fallback am Avatar-Kaestchen (Default-Optik gepinnt)' do
      # The class is the ONLY background of the uncolored tile — if the
      # `unless org_color` fallback in the view is dropped, the box becomes transparent
      # (silent visual regression that no other assert sees). Anchored on the avatar div,
      # because 'bg-cream-200' can also appear as an aria-pressed: variant in the document.
      # The opposite direction (class ALSO on the colored tile) DELIBERATELY left
      # unpinned: the inline style wins -> equivalent mutant.
      join_org
      get select_organisation_path
      expect(response.body).to match(/w-12 h-12 rounded-lg bg-cream-200/)
    end
  end

  context 'Kontext-uebergreifende Konsistenz (Sidebar <-> Auswahl-Kachel)' do
    it 'zeigt dieselbe Org-Farbe in der Sidebar (Org-Seite) UND auf der Auswahl-Kachel' do
      # This is the actual purpose: recognizing color <-> org across both contexts.
      org_a = join_org
      join_org
      user.org_colors.set(org_a, '#dbeafe')

      get organisation_appearance_path(org_a)
      expect(response.body).to include('--brand: 219 234 254;') # sidebar chip (variable)

      get select_organisation_path
      expect(response.body).to include('background-color: #dbeafe;') # selection tile (inline)
    end
  end
end
