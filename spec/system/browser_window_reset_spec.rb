# frozen_string_literal: true

require 'rails_helper'

# What:  An example that resizes the browser window does not hand that size to
#        the next one (BrowserWindow in spec/support/capybara.rb).
# Type:  System spec. Each driver keeps one Chrome for the whole run, so the
#        window is state every browser example shares.
# Why:   Until 13.11.2026 a resize stayed. Four examples were green alone and red
#        in the full run, always in the same order: the file before them had left
#        the window at 1440 px, where a table column they look for has no room
#        and a width they measure is still easing.
#
# Each driver gets two examples. Both expect the driver's own size at their start
# and leave another one behind, so whichever of the two runs second fails when
# nothing puts the window back. No example relies on the other's data.
RSpec.describe 'Browser window between examples', type: :system do
  let(:left_behind) { [1000, 700] }

  def window_size
    size = page.driver.browser.manage.window.size
    [size.width, size.height]
  end

  %i[selenium_chrome_headless selenium_chrome_headless_full].each do |driver|
    context "with #{driver}" do
      # In the group's own before block, like the specs that pick the faithful
      # driver: this runs after every hook of the configuration.
      before { driven_by driver }

      2.times do |round|
        it "finds the driver's own window size and may leave another (#{round + 1})" do
          expect(window_size).to eq(BrowserWindow::SIZES.fetch(driver))

          page.driver.browser.manage.window.resize_to(*left_behind)
          expect(window_size).to eq(left_behind)
        end
      end
    end
  end

  it 'starts each driver with the size the table names' do
    expect(BrowserWindow.size_argument(:selenium_chrome_headless)).to eq('--window-size=1920,1080')
    expect(BrowserWindow.size_argument(:selenium_chrome_headless_full)).to eq('--window-size=1440,900')
  end
end
