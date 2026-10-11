# frozen_string_literal: true

require 'rails_helper'

# What:  A ticket description with Trix-era images is edited in Lexxy, the references
#        survive, and the rendered description offers the zoom lightbox.
# Type:  System spec with headless Chrome (doc/inline_bilder_paket_2_plan.md, P2-5,
#        2026-08-23). Runs by hand: spec/system is not in the CI list.
# Why:   S9 proved the round trip for notes; tickets carry 38 of the 88 production embeds
#        and use a different form (turbo frame, ticket_document_files redirect target).
#        The lightbox is delegated on the content wrapper because ActionText strips data
#        attributes from the attachment partial; this is the only place that clicks it.
RSpec.describe 'Lexxy on tickets: editing Trix-era images and zooming', type: :system do
  before { Prosopite.pause }
  after { Prosopite.resume }

  around do |example|
    adapter_was = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = adapter_was
  end

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:png) { Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==') }
  let(:blob) { ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png), filename: 'ablauf.png', content_type: 'image/png') }
  let(:trix_html) do
    %(<div>Schritt 1</div><action-text-attachment sgid="#{blob.attachable_sgid}" content-type="image/png" filename="ablauf.png" filesize="#{blob.byte_size}" width="1" height="1"></action-text-attachment><div>Schritt 2</div>)
  end
  let!(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: 'Fallbeschreibung', content: '<div>x</div>').tap do |t|
        t.content.body = trix_html
        t.save!(validate: false)
      end
    end
  end

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    end
    login_as(user, scope: :user)
  end

  it 'shows the image with a zoom link, opens the lightbox, and keeps the image through a Lexxy edit' do
    visit organisation_project_ticket_path(organisation, project, ticket)
    expect(page).to have_css('.lexxy-content a.attachment__zoom img', wait: 10)

    find('.lexxy-content a.attachment__zoom', match: :first).click
    expect(page).to have_css('dialog.rich-text-zoom[open] img.rich-text-zoom__image', wait: 5)
    find('dialog.rich-text-zoom .rich-text-zoom__close').click
    expect(page).to have_no_css('dialog.rich-text-zoom', wait: 5)

    find('a[href*="/edit"][data-turbo-frame="writing_surface"]', match: :first).click
    # The comment form has an editor too: address the one inside the writing surface
    # (Paket 3: edit opens the surface in turbo-frame#writing_surface).
    editor = find('.writing-surface lexxy-editor[name="ticket[content]"]', wait: 10)
    expect(editor['data-neo-rich-text-embeds-attachment-selector-value']).to include('ticket_document_files')
    content_selector = %(.writing-surface lexxy-editor[name="ticket[content]"] .lexxy-editor__content)
    expect(page).to have_css(content_selector, wait: 10)
    sleep 1
    expect(page.evaluate_script("document.querySelector('#{content_selector}').innerHTML")).to include('ablauf.png')

    page.execute_script(<<~JS)
      const content = document.querySelector('#{content_selector}');
      content.focus();
      const selection = window.getSelection();
      selection.selectAllChildren(content);
      selection.collapseToEnd();
    JS
    find(content_selector).send_keys(' Nachtrag')
    find('.writing-surface button[type="submit"]').click

    expect(page).to have_content('Nachtrag', wait: 10)
    expect(page).to have_css('.lexxy-content a.attachment__zoom img', wait: 10)
    sleep 1
    expect(ticket.content.reload.embeds.count).to eq(1)
    expect(ticket.content.body.to_html).to include('Nachtrag').and include(blob.attachable_sgid)
  end
end
