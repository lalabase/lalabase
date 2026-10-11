# frozen_string_literal: true

require 'rails_helper'

# Guards the unified attachment render path. Post attachments used to render through a
# divergent twin partial (organisations/posts/_attachment) that missed PR #140's
# click-to-open fix. The component now renders shared/_attachment, so a PDF/file in a
# post is a real open-in-new-tab link with affordance — not dead plain text.
RSpec.describe NeoPostComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  let(:post_record) do
    ActsAsTenant.with_tenant(organisation) do
      project = create(:project, organisation: organisation)
      ticket  = create(:ticket, project: project, organisation: organisation)
      post    = create(:post, ticket: ticket, organisation: organisation, user: user)
      # A .zip is never previewable on any host, so this deterministically exercises the
      # file-chip else branch — the same branch a PDF takes on a host without pdftoppm,
      # which is exactly the plain-text "won't open" case the user reported. (The
      # PDF => PDF-icon mapping is proven deterministically in attachments_helper_spec.)
      create(:post_document, :with_unsupported_file, post: post, organisation: organisation)
      post
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  subject(:component) do
    described_class.new(
      post: post_record,
      current_user: user,
      current_organisation: organisation,
      show_edit_button: false, # short-circuits PostPolicy; not what this spec is about
      turbo_frame: false
    )
  end

  it 'renders the previews without the old section banner (T4 quiet thread)' do
    render_inline(component)
    # The ornamental "Anhänge (n)" divider is gone by design; the previews
    # themselves stay (the link examples below pin the render path).
    expect(page).not_to have_text('Anhänge')
  end

  it 'renders the attachment as an open-in-new-tab link via the shared partial' do
    render_inline(component)

    link = page.find('a[target="_blank"]', match: :first)
    expect(link[:rel].to_s).to include('noopener')
    # The authorized proxy path for a post document, not the unprotected default blob route.
    expect(link[:href]).to include('/files/post_document/')
    expect(link[:href]).not_to include('/rails/active_storage/')
  end

  it 'gives the file link a recognizable affordance (type icon + underline)' do
    render_inline(component)
    link = page.find('a[target="_blank"]', match: :first)

    expect(link).to have_css('i.bi-file-earmark-zip')
    expect(link[:class].to_s).to include('underline')
  end

  it 'shows the reaction picker and the current reaction count to ticket writers' do
    role = create(:admin_role, organisation: organisation)
    create(:membership, organisation: organisation, user: user, role: role, active: true)
    create(:post_reaction, organisation: organisation, post: post_record, user: user, emoji: '👍')

    render_inline(component)

    expect(page).to have_button('Reaktion hinzufügen')
    expect(page).to have_button('Eigene Reaktion 👍 entfernen')
    expect(page).to have_css('[data-post-reactions-for]', text: '1')
  end

  it 'shows existing reactions without controls to ticket readers' do
    role = create(:role, title: 'Ticket-Leser', organisation: organisation)
    create(:project_read_permission, role: role, area: 'tickets')
    create(:membership, organisation: organisation, user: user, role: role, active: true)
    create(:post_reaction, organisation: organisation, post: post_record, user: create(:user), emoji: '✅')

    render_inline(component)

    expect(page).to have_css('[data-post-reactions-for]', text: /✅\s*1/)
    expect(page).to have_no_button('Reaktion hinzufügen')
    expect(page).to have_no_css('button[aria-label*="Reaktion ✅"]')
  end

  it 'changes its cache key when a reaction is added or removed' do
    initial_digest = component.send(:reactions_digest)
    reaction = create(:post_reaction, organisation: organisation, post: post_record, user: user)
    added_digest = described_class.new(
      post: post_record.reload, current_user: user, current_organisation: organisation,
      show_edit_button: false, turbo_frame: false
    ).send(:reactions_digest)
    reaction.destroy!
    removed_digest = described_class.new(
      post: post_record.reload, current_user: user, current_organisation: organisation,
      show_edit_button: false, turbo_frame: false
    ).send(:reactions_digest)

    expect(added_digest).not_to eq(initial_digest)
    expect(removed_digest).to eq(initial_digest)
  end
end
