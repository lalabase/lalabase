# frozen_string_literal: true

require 'rails_helper'

# The head of the sidebar in a real browser (user, 19.11.2026): the gear and the chevron
# of the switcher carry no edge of their own, like the head buttons of the assistant panel.
# The chevron stands at the name it changes, right behind it also when a long name is cut,
# and turns when the menu opens. The gear shows a grey tile under the pointer, and the same
# tile marks the management area, set apart from the head in every theme.
RSpec.describe 'Signs in the head of the sidebar (System)', type: :system do
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nordwind Logistik und Spedition GmbH') }
  let(:south) { create(:organisation, name: 'Suedhang AG') }

  def join(org)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, role: create(:admin_role, organisation: org), active: true)
    end
  end

  def style_of(element, property)
    element.evaluate_script("getComputedStyle(this).#{property}")
  end

  def rgb(element)
    style_of(element, 'backgroundColor').scan(/\d+/).first(3).map(&:to_i)
  end

  # Waits for a value at rest: colours ease in.
  def expect_style(element, property, value)
    page.document.synchronize(Capybara.default_max_wait_time) do
      actual = style_of(element, property)
      raise Capybara::ExpectationNotMet, "#{property} is #{actual}, expected #{value}" unless actual == value
    end
  end

  def head = find('[data-sidebar-header] summary')
  def gear = head.find("a[href='#{organisation_settings_path(north)}']")
  def sign = head.find('[data-sidebar-switcher-sign]', visible: :all)

  before do
    join(north)
    join(south)
    login_as(user, scope: :user)
    page.current_window.resize_to(1440, 1000)
  end

  it 'puts the sign right behind the cut name and gives neither the sign nor the gear an edge' do
    visit organisation_notifications_path(north, state_filters: %w[read unread])

    name = head.find('h3 > span.truncate')
    expect(name.evaluate_script('this.scrollWidth > this.clientWidth')).to be(true) # the name is cut
    name_right = name.evaluate_script('this.getBoundingClientRect().right')
    sign_left = sign.evaluate_script('this.getBoundingClientRect().left')
    expect(sign_left - name_right).to be_between(0, 4)
    expect(sign).to have_css('i.bi-chevron-down', visible: :all)

    [sign, gear].each do |element|
      expect(style_of(element, 'borderTopWidth')).to eq('0px')
      expect(style_of(element, 'boxShadow')).to eq('none')
    end
    expect(style_of(gear, 'backgroundColor')).to eq('rgba(0, 0, 0, 0)')
  end

  it 'shows a grey tile on the gear under the pointer only' do
    visit organisation_notifications_path(north, state_filters: %w[read unread])

    head.find('h3').hover
    expect_style(gear, 'backgroundColor', 'rgba(0, 0, 0, 0)')

    gear.hover
    page.document.synchronize do
      raise Capybara::ExpectationNotMet, 'no tile yet' if style_of(gear, 'backgroundColor') == 'rgba(0, 0, 0, 0)'
    end
  end

  it 'turns the chevron when the menu opens, without a tile' do
    visit organisation_notifications_path(north, state_filters: %w[read unread])
    chevron = sign.find('i', visible: :all)
    expect(style_of(chevron, 'transform')).to eq('none')

    head.click
    expect(page).to have_css('[data-sidebar-header] details[open]')
    page.document.synchronize do
      raise Capybara::ExpectationNotMet, 'not turned yet' if style_of(chevron, 'transform') == 'none'
    end
    expect(style_of(sign, 'backgroundColor')).to eq('rgba(0, 0, 0, 0)')
  end

  # The management area keeps the gear on its tile. In every theme the tile must stand
  # apart from the head it sits on (the summed channel distance: the globe's tile on the
  # current page's row was 24 in the dark theme, seen, hardly; this tile is 39 in the
  # light theme, plainly seen).
  { 'light' => nil, 'dark' => 'dark', 'pop' => 'theme-pop' }.each do |theme, theme_class|
    it "marks the management area with the gear's tile in the #{theme} theme" do
      visit organisation_settings_path(north)
      page.execute_script(<<~JS)
        document.documentElement.classList.remove('dark', 'theme-pop');
        #{"document.documentElement.classList.add('#{theme_class}');" if theme_class}
      JS
      find('main').hover

      surface = find('[data-sidebar-header]').find(:xpath, './ancestor::aside[1]')
      # The colours ease after the theme switch (transition-colors): read them at rest.
      distance = nil
      page.document.synchronize do
        distance = rgb(gear).zip(rgb(surface)).sum { |a, b| (a - b).abs }
        raise Capybara::ExpectationNotMet, "distance #{distance}" if distance < 30
      end
      expect(distance).to be >= 30
    end
  end
end
