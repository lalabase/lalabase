# frozen_string_literal: true

require 'rails_helper'

# GHSA-8qw7-6phv-7q6p: populated slots and with_content must never survive
# into another request through a reused component instance.
RSpec.describe 'ViewComponent render isolation', :ci_guard, type: :component do
  def populated_component(kind, text)
    case kind
    when :single_slot
      NeoTitleBoxComponent.new(title: 'Header').tap do |component|
        component.with_right_content { text }
      end
    when :multiple_slots
      Neo::OverflowMenuComponent.new.tap do |component|
        component.with_item(label: text, url: '/example')
      end
    when :with_content
      NeoTagComponent.new.with_content(text)
    end
  end

  %i[single_slot multiple_slots with_content].each do |kind|
    it "rejects a second render of an instance populated through #{kind}" do
      component = populated_component(kind, 'First user private content')
      with_request_url('/org/first') { render_inline(component) }
      expect(page).to have_text(:all, 'First user private content')

      with_request_url('/org/second') do
        expect { render_inline(component) }.to raise_error do |error|
          expect(error.class.name).to eq('ViewComponent::ReusedInstanceError')
        end
      end
    end

    it "keeps #{kind} content separate for fresh instances in successive requests" do
      with_request_url('/org/first') do
        render_inline(populated_component(kind, 'First user private content'))
      end
      expect(page).to have_text(:all, 'First user private content')

      with_request_url('/org/second') do
        render_inline(populated_component(kind, 'Second user private content'))
      end
      expect(page).to have_text(:all, 'Second user private content')
      expect(page).to have_no_text(:all, 'First user private content')
    end
  end
end
