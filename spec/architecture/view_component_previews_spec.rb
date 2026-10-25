# frozen_string_literal: true

require 'rails_helper'

# The configured spec/components/previews path must remain discoverable after
# a ViewComponent upgrade, including the preview with a sidecar ERB template.
RSpec.describe 'ViewComponent previews', type: :request do
  before do
    # The app layout requires authenticated helpers and already breaks previews
    # on main. Check discovery and example rendering independently of that layout.
    allow(Neo::Buttons::ButtonComponentPreview).to receive(:render_args).and_wrap_original do |method, *args, **kwargs|
      method.call(*args, **kwargs).merge(layout: false)
    end
  end

  {
    'default' => 'Button Text',
    'all_variants' => 'Primary',
    'with_icon' => 'Edit Item',
    'loading_state' => 'Processing...',
    'with_confirmation' => 'Delete',
    'as_link' => 'New Item',
    'disabled' => 'Disabled Button',
    'form_delete' => 'Delete Item'
  }.each do |example, label|
    it "renders the #{example} button preview" do
      get "/rails/view_components/neo/buttons/button_component/#{example}"

      expect(response).to have_http_status(:ok)
      controls = Nokogiri::HTML5(response.body).css('button, a').map { |node| node.text.squish }
      expect(controls).to include(label)
    end
  end
end
