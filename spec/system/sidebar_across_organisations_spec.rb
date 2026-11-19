# frozen_string_literal: true

require 'rails_helper'

# The globe at the end of the sidebar's "Inbox" and "Personen" rows in a real browser:
# how it shows, which the request spec (spec/requests/sidebar_across_organisations_spec.rb)
# cannot see. Three steps, so the sidebar stays quiet (user, 19.11.2026): hidden while
# nothing points at the row, faint while the row is hovered, whole and on a grey tile
# (the assistant panel's head buttons) while the globe itself is hovered. The row keeps
# its hover look while the pointer is on the globe, and a click on the globe leaves for
# the page above the organisations.
RSpec.describe 'Globe to the pages above the organisations in the sidebar (System)', type: :system do
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nordwind GmbH') }
  let(:south) { create(:organisation, name: 'Suedhang AG') }

  def join(org)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, role: create(:admin_role, organisation: org), active: true)
    end
  end

  def row_item(path)
    find("a.sidebar-row[href='#{path}']").find(:xpath, '..')
  end

  def style_of(element, property)
    element.evaluate_script("getComputedStyle(this).#{property}")
  end

  # The globe eases in 120 ms: wait for the value at rest, not for a time.
  def expect_style(element, property, value)
    page.document.synchronize(Capybara.default_max_wait_time) do
      actual = style_of(element, property)
      raise Capybara::ExpectationNotMet, "#{property} is #{actual}, expected #{value}" unless actual == value
    end
  end

  before do
    join(north)
    join(south)
    login_as(user, scope: :user)
    page.current_window.resize_to(1440, 1000)
    visit organisation_people_path(north)
  end

  it 'hides the globe at rest, shows it faint on the row and whole on its tile on itself' do
    item = row_item(organisation_people_path(north))
    globe = item.find('a[data-sidebar-across]', visible: :all)

    expect_style(globe, 'opacity', '0')
    expect(style_of(globe, 'pointerEvents')).to eq('none')

    item.find('a.sidebar-row').hover
    expect_style(globe, 'opacity', '0.5')
    expect(style_of(globe, 'backgroundColor')).to eq('rgba(0, 0, 0, 0)')

    # The tile of the assistant panel's head buttons: a grey fill, no edge, no shadow.
    globe.hover
    expect_style(globe, 'opacity', '1')
    expect_style(globe, 'backgroundColor', page.evaluate_script(<<~JS))
      (() => { const probe = document.createElement('span'); probe.className = 'bg-cream-200';
               document.body.append(probe); const value = getComputedStyle(probe).backgroundColor;
               probe.remove(); return value })()
    JS
    expect(style_of(globe, 'borderTopWidth')).to eq('0px')
    expect(style_of(globe, 'boxShadow')).to eq('none')
  end

  it 'keeps the hover look of a row that is not the current page while the pointer is on the globe' do
    item = row_item(organisation_notifications_path(north))
    row = item.find('a.sidebar-row')
    resting = style_of(row, 'backgroundColor')

    row.hover
    hovered = style_of(row, 'backgroundColor')
    expect(hovered).not_to eq(resting)

    item.find('a[data-sidebar-across]', visible: :all).hover
    expect(style_of(row, 'backgroundColor')).to eq(hovered)
  end

  # The current page's row is the raised surface. In every theme the tile must stand
  # apart from it; in the dark theme cream-200 did not (19.11.2026).
  { 'light' => nil, 'dark' => 'dark', 'pop' => 'theme-pop' }.each do |theme, theme_class|
    it "sets the tile apart from the current page's row in the #{theme} theme" do
      page.execute_script(<<~JS)
        document.documentElement.classList.remove('dark', 'theme-pop');
        #{"document.documentElement.classList.add('#{theme_class}');" if theme_class}
      JS
      item = row_item(organisation_people_path(north)) # the current page
      row = item.find('a.sidebar-row')
      row.hover
      globe = item.find('a[data-sidebar-across]')
      globe.hover
      expect_style(globe, 'opacity', '1')

      # Summed channel distance. cream-200 on the dark row was 24 (seen, hardly), the
      # light theme's tile is 91, pop's 129.
      tile, surface = [globe, row].map { |el| style_of(el, 'backgroundColor').scan(/\d+/).first(3).map(&:to_i) }
      expect(tile.zip(surface).sum { |a, b| (a - b).abs }).to be >= 40
    end
  end

  it 'shows the globe faint while the row holds the keyboard focus' do
    item = row_item(organisation_notifications_path(north))
    globe = item.find('a[data-sidebar-across]', visible: :all)

    item.find('a.sidebar-row').execute_script('this.focus()')
    expect_style(globe, 'opacity', '0.5')
  end

  it 'leaves for the people above the organisations on a click on the globe' do
    item = row_item(organisation_people_path(north))
    item.find('a.sidebar-row').hover
    item.find('a[data-sidebar-across]').click

    expect(page).to have_current_path(all_people_path)
  end
end
