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

  it 'covers all management pages offered by the shared navigation' do
    expect(described_class::PAGE_TITLE_KEYS.keys).to include(*NavigationHelper::SETTINGS_TAB_CONTROLLERS,
                                                             *NavigationHelper::AI_AREA_CONTROLLERS)
  end
end
