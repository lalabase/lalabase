# frozen_string_literal: true

require 'rails_helper'

# Pins the colour assignment of the flash: success and notice are green (F25),
# lime belongs to the primary action only. There was no spec for this component
# before the lime clean-up (06.09.2026), so the fill was never guarded.
RSpec.describe NeoFlashComponent, type: :component do
  %i[notice success].each do |type|
    it "renders a #{type} flash with a green fill and a green check icon" do
      render_inline(described_class.new(type: type, message: 'Saved'))

      expect(page).to have_css('.bg-green-100')
      expect(page).to have_css('i.bi-check-circle-fill.text-green-700')
      expect(page).not_to have_css('[class*="bg-lime"]')
      expect(page).to have_content('Saved')
    end
  end

  it 'keeps the other types on their own fills' do
    render_inline(described_class.new(type: :alert, message: 'Failed'))
    expect(page).to have_css('.bg-red-100')

    render_inline(described_class.new(type: :warning, message: 'Careful'))
    expect(page).to have_css('.bg-yellow-100')

    render_inline(described_class.new(type: :info, message: 'Note'))
    expect(page).to have_css('.bg-cobalt-100')
  end

  it 'renders nothing without a message' do
    render_inline(described_class.new(type: :notice, message: nil))

    expect(rendered_content).to be_blank
  end
end
