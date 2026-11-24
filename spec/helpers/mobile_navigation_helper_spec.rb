# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MobileNavigationHelper, type: :helper do
  before do
    allow(helper).to receive(:mobile_project).and_return(nil)
    allow(helper).to receive(:mobile_active_destination).and_return('more')
  end

  it 'uses the localized More title for an unknown page' do
    allow(helper).to receive(:controller_name).and_return('future_org_page')
    I18n.with_locale(:de) { expect(helper.mobile_page_title).to eq('Mehr') }
    I18n.with_locale(:en) { expect(helper.mobile_page_title).to eq('More') }
  end

  it 'has a translated title for every registered page in both languages' do
    expect(described_class::PAGE_TITLE_KEYS).to be_frozen
    described_class::PAGE_TITLE_KEYS.each do |controller_name, key|
      allow(helper).to receive(:controller_name).and_return(controller_name)
      %i[de en].each do |locale|
        I18n.with_locale(locale) do
          expect(I18n.exists?(key, locale)).to be(true), "Missing #{locale} title for #{controller_name}: #{key}"
          expect(helper.mobile_page_title).to eq(I18n.t(key))
        end
      end
    end
  end

  # Every page the sidebar counts as management (NavigationHelper.section_key_for): the
  # sections, and the pages below them, the access overview, the invitation form and
  # every AI page among them. A phone has no such sidebar; without an entry its header
  # says "Mehr" (spec/system/management_phone_spec.rb).
  it 'covers all management pages offered by the shared navigation' do
    expect(described_class::PAGE_TITLE_KEYS.keys).to include(*NavigationHelper::SETTINGS_TAB_CONTROLLERS,
                                                             *NavigationHelper::MANAGEMENT_PAGE_SECTIONS.keys)
  end

  # The fixed head on a phone and the page head never say the same thing
  # twice (user, 2026-11-24: "Start" over "Übersicht", "Verwaltung" over
  # "Allgemein", the organisation twice). The page head asks #mobile_head_echo
  # which of its lines to hide; the phone itself: spec/system/phone_page_head_spec.rb.
  describe 'the page head under the fixed head' do
    let(:organisation) { build_stubbed(:organisation, name: 'Nordlicht & Co') }

    # Controller helpers a helper spec's view does not have (as in inbox_helper_spec).
    before do
      org = organisation
      helper.define_singleton_method(:current_organisation) { org }
      helper.define_singleton_method(:user_signed_in?) { true }
      allow(helper).to receive(:controller_name).and_return('organisation_settings')
    end

    it 'has no phone shell without an organisation, and never asks Devise then' do
      allow(helper).to receive(:current_organisation).and_return(nil)
      allow(helper).to receive(:user_signed_in?).and_raise('Devise was asked')

      expect(helper.mobile_shell?).to be(false)
      expect(helper.mobile_head_echo(title: 'Allgemein', line: nil)).to eq(title: false, line: false)
      expect(helper.request.env).not_to have_key(described_class::MOBILE_HEAD_ENV_KEY)
    end

    it 'has no phone shell for a visitor who is not signed in' do
      allow(helper).to receive(:user_signed_in?).and_return(false)

      expect(helper.mobile_head_echo(title: 'Allgemein', line: 'Nordlicht & Co')).to eq(title: false, line: false)
      expect(helper.mobile_page_title).to eq(I18n.t('navigation.management'))
    end

    it 'names the page in the words of its first head, outside a project' do
      expect(helper.mobile_head_echo(title: 'Allgemein', line: 'Nordlicht & Co')).to eq(title: true, line: true)

      expect(helper.mobile_page_title).to eq('Allgemein')
      expect(helper.mobile_page_line).to eq('Nordlicht & Co')
    end

    it 'puts the head\'s own second line where the organisation stood' do
      helper.mobile_head_echo(title: 'Profil', line: 'Anna Beispiel')

      expect(helper.mobile_page_line).to eq('Anna Beispiel')
    end

    it 'keeps the organisation as the second line of a head without one' do
      expect(helper.mobile_head_echo(title: 'Projekte', line: nil)).to eq(title: true, line: true)

      expect(helper.mobile_page_line).to eq('Nordlicht & Co')
    end

    it 'leaves a later head of the same page what the fixed head does not show' do
      helper.mobile_head_echo(title: 'Allgemein', line: 'Nordlicht & Co')

      expect(helper.mobile_head_echo(title: 'Vorschau', line: 'Nordlicht & Co')).to eq(title: false, line: true)
      expect(helper.mobile_head_echo(title: 'Allgemein', line: 'Entwurf')).to eq(title: true, line: false)
      expect(helper.mobile_page_title).to eq('Allgemein')
    end

    context 'inside a project' do
      let(:project) { instance_double(Project, name: 'Leuchtturm') }

      before do
        allow(helper).to receive_messages(mobile_project: project, mobile_area: 'knowledge')
        allow(helper).to receive(:mobile_project_items).with(project).and_return(
          [{ key: 'tickets', label: 'Tickets', path: '/t' }, { key: 'knowledge', label: 'Wissen', path: '/k' }]
        )
      end

      it 'keeps the project and the tabs in the fixed head, and hides what they already say' do
        expect(helper.mobile_head_echo(title: 'Wissen', line: 'Leuchtturm')).to eq(title: true, line: true)
        expect(helper.mobile_page_title).to eq('Leuchtturm')
        expect(helper.mobile_page_line).to eq('Nordlicht & Co')
        expect(helper.request.env).not_to have_key(described_class::MOBILE_HEAD_ENV_KEY)
      end

      it 'keeps the title of a page below an area and a second line of its own' do
        expect(helper.mobile_head_echo(title: 'Repository verbinden', line: 'Leuchtturm')).to eq(title: false, line: true)
        expect(helper.mobile_head_echo(title: 'Attribut bearbeiten', line: 'Status')).to eq(title: false, line: false)
        expect(helper.mobile_head_echo(title: 'Tickets', line: nil)).to eq(title: false, line: false)
      end
    end
  end
end
