# frozen_string_literal: true

require 'rails_helper'

# What:  Lexxy is scoped to wiki notes ONLY — Trix stays the editor everywhere else.
# Type:  Integration guard (renders the form helpers, no browser, no DB writes).
# Why:   The lexxy gem registers itself as a GLOBAL Action Text editor on Rails 8.0.x —
#        it aliases rich_text_area -> Lexxy for EVERY model (Tickets, Posts, …).
#        config/initializers/lexxy.rb turns that off and we opt notes in explicitly via
#        form.lexxy_rich_text_area. This guard turns red if the global override is ever
#        re-enabled (gem upgrade, deleted/edited initializer), which would silently switch
#        every Trix editor in the app to Lexxy.
RSpec.describe 'Lexxy editor scoping' do
  # Note.new is acts_as_tenant-scoped; we only render (never save), so without_tenant is fine.
  def render_note_form(helper)
    ActsAsTenant.without_tenant do
      ApplicationController.render(
        inline: "<%= form_with(model: Note.new, url: '/x') { |f| f.#{helper} :content } %>"
      )
    end
  end

  it 'renders a <lexxy-editor> for notes via lexxy_rich_text_area' do
    html = render_note_form('lexxy_rich_text_area')
    expect(html).to include('<lexxy-editor')
    expect(html).not_to include('<trix-editor')
  end

  it 'keeps Trix as the default rich_text_area editor (global override disabled)' do
    html = render_note_form('rich_text_area')
    expect(html).to include('<trix-editor')
    expect(html).not_to include('<lexxy-editor')
  end
end
