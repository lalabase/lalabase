# frozen_string_literal: true

require 'rails_helper'

# What:  There is exactly ONE ticket form: organisations/tickets/_writing_surface.html.erb.
# Type:  Static guard (doc/inline_bilder_paket_3_plan.md, P3-4, 2026-08-23).
# Why:   Before Paket 3 the ticket form existed three times (index modal, dashboard modal,
#        inline header edit) and every field, rule or hint had to be added three times; the
#        dashboard copy had already drifted. A second copy is the first step back. The marker
#        is the ticket editor's attachment field passed to lexxy_embed_editor_options: any
#        template that renders a ticket description editor has to name it.
RSpec.describe 'Single ticket form' do
  let(:ticket_editor_marker) { 'attachment_field: "ticket[ticket_document_files][]"' }
  let(:the_form) { 'app/views/organisations/tickets/_writing_surface.html.erb' }

  def templates_with(marker)
    Dir[Rails.root.join('app/{views,components}/**/*.erb')]
      .select { |f| File.read(f).include?(marker) }
      .map { |f| Pathname(f).relative_path_from(Rails.root).to_s }
  end

  it 'renders the ticket description editor in the writing surface and nowhere else' do
    expect(templates_with(ticket_editor_marker)).to eq([the_form])
  end

  it 'has no leftovers of the three former forms' do
    %w[_ticket_form_with_errors.html.erb _ticket_header_edit.html.erb edit.html.erb _edit.html.erb edit.turbo_stream.erb].each do |name|
      expect(Rails.root.join('app/views/organisations/tickets', name)).not_to exist, name
    end
  end
end
