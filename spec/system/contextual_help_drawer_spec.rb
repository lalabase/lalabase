# frozen_string_literal: true

require 'rails_helper'

# What: The contextual-help drawer end-to-end (doc/kontexthilfe_drawer_plan.md,
#       Slice B): "?" menu on a ticket list → question click opens the right
#       slide-over instead of navigating away, the turbo-frame grafts the help
#       content, the drawer scrolls to the question's anchor and flashes it;
#       closing (ESC / close button / backdrop) releases the scroll lock and
#       returns focus; the header escape hatch navigates to the full help page.
# Type: System spec (real browser) — the whole point of the feature is JS
#       behaviour (preventDefault on the link, dynamic frame src, anchor scroll,
#       focus management); request specs cover the server-side seam
#       (spec/requests/help_contextual_frame_spec.rb).
# Why:  Guards the two dogfooding pains the drawer exists for: the work page
#       must stay (URL untouched), and the answer must be findable (anchor
#       scroll + highlight) — plus the no-dead-end contract (D5 escape hatch).
RSpec.describe 'Kontexthilfe-Drawer (System)', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  # The tickets question with a locale anchor — exercises the scroll+highlight path.
  # Question, slug and anchor are the REAL entry from Docs::ContextualHelp, which
  # this repository owns. The PAGE behind it comes from the catalogue another
  # program writes, and the recorded one here is a two-page example, so this
  # example supplies a page at that slug carrying that anchor. It is about the
  # drawer, not about the handbook: whether the real handbook still answers under
  # that anchor is measured by `rake anchors:check` in
  # gboyke/lalabase-documentation.
  let(:question) do
    # fetch-like, not find: if the map entry is renamed or dropped, say which
    # slug went missing instead of failing later with NoMethodError on nil.
    Docs::ContextualHelp.for(:tickets).find { |entry| entry[:slug] == help_slug } ||
      raise("no contextual help question for #{help_slug}")
  end
  let(:help_slug) { 'guides/ticket-views/assign-status' }
  let(:question_label) { I18n.t(question[:label_key], locale: :de) }
  let(:anchor) { question[:anchor][:de] }

  before do
    write_docs_catalogue(
      de: [docs_catalogue_page(
        slug: help_slug, title: 'Status und Zuweisung',
        html: <<~HTML
          <h1 id="status-und-zuweisung">Status und Zuweisung</h1>
          <p>Platzhaltertext, damit der Auszug etwas zu scrollen hat.</p>
          #{'<p>Absatz, der Höhe schafft.</p>' * 40}
          <h2 id="#{anchor}">Ticket beobachten</h2>
          <p>Der Abschnitt, auf den die Frage zeigt.</p>
        HTML
      )]
    )

    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    login_as(user, scope: :user)
  end

  def open_drawer_from_tickets
    visit organisation_project_tickets_path(organisation, project)
    find("[title='#{I18n.t('components.contextual_help.label', locale: :de)}']").click
    click_link question_label
  end

  it 'öffnet die Antwort im Drawer, scrollt zum Anker und lässt die Arbeitsseite stehen' do
    open_drawer_from_tickets

    # Drawer is open, the frame grafted the help content, the anchor section is there.
    expect(page).to have_css('[data-contextual-help-drawer-target="overlay"]:not(.hidden)')
    within('turbo-frame#contextual_help_content') do
      expect(page).to have_css("##{anchor}")
    end

    # The work page was NOT navigated away (pain #1 from dogfooding).
    expect(page).to have_current_path(
      organisation_project_tickets_path(organisation, project), ignore_query: true
    )

    # Anchor scroll + short highlight (pain #2): the drawer body scrolled down to
    # the section and the heading carries the flash class right after loading.
    expect(page).to have_css("##{anchor}.contextual-help-highlight")
    scroll_top = page.evaluate_script(
      "document.querySelector('[data-contextual-help-drawer-target=\"scrollContainer\"]').scrollTop"
    )
    expect(scroll_top).to be_positive

    # The "?" dropdown behind the drawer was closed when the drawer took over.
    expect(page).to have_no_css('[data-dropdown-target="menu"]:not(.hidden)')
  end

  it 'schließt per ESC, gibt den Body-Scroll frei und fokussiert den Trigger zurück' do
    open_drawer_from_tickets
    expect(page).to have_css('[data-contextual-help-drawer-target="overlay"]:not(.hidden)')
    expect(page).to have_css('body.modal-open')

    # To the document, not the active element: for a moment that is still the
    # link in the "?" menu the drawer just hid, and a hidden element takes no keys.
    find('body').send_keys(:escape)

    expect(page).to have_no_css('[data-contextual-help-drawer-target="overlay"]:not(.hidden)')
    expect(page).to have_no_css('body.modal-open')
    # Focus returned to the visible "?" trigger (not the link inside the hidden menu).
    expect(page.evaluate_script("document.activeElement.getAttribute('title')"))
      .to eq(I18n.t('components.contextual_help.label', locale: :de))
  end

  it 'schließt per Schließen-Button und per Backdrop-Klick' do
    open_drawer_from_tickets
    find("[aria-label='#{I18n.t('components.contextual_help.close', locale: :de)}']").click
    expect(page).to have_no_css('[data-contextual-help-drawer-target="overlay"]:not(.hidden)')

    # Reopen, then close via a click on the backdrop (viewport center is left of
    # the right-hand panel on a desktop window).
    find("[title='#{I18n.t('components.contextual_help.label', locale: :de)}']").click
    click_link question_label
    expect(page).to have_css('[data-contextual-help-drawer-target="overlay"]:not(.hidden)')
    find('[data-contextual-help-drawer-target="overlay"]').click
    expect(page).to have_no_css('[data-contextual-help-drawer-target="overlay"]:not(.hidden)')
  end

  it 'navigiert über „Ganze Seite öffnen" regulär zur vollen Hilfe-Seite (D5)' do
    open_drawer_from_tickets

    link = find('[data-contextual-help-drawer-target="fullPageLink"]')
    expect(link[:href]).to end_with("/hilfe/#{help_slug}##{anchor}")

    link.click

    # Full page incl. tree/search — the drawer is gone with the navigation.
    # (current_path never carries the fragment — assert on the full URL.)
    expect(page).to have_css('#help-page')
    expect(page).to have_css('turbo-frame#contextual_help_content .help-prose')
    expect(page.current_url).to end_with("/hilfe/#{help_slug}##{anchor}")
  end
end
