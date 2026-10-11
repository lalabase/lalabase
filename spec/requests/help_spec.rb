# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require 'fileutils'

# What: The in-app help (HelpController) — auth boundary, org-free reachability,
#       surface scoping at request level, index/show flows, EN→DE fallback
#       banner, 404.
# Type: Request spec against the recorded catalogue (spec/fixtures/docs_catalogue,
#       two example pages the documentation repository wrote), plus built
#       catalogues for the fallback banner and the sanitize gate, which the
#       recording cannot reproduce.
#
#       The recording is an example and not the handbook, so nothing here may
#       lean on what a real page SAYS. What it may lean on is the shape: two
#       pages in one section, the first linking to the second.
# Why:  The help serves the HELP surface of the shared docs engine behind the
#       login, deliberately OUTSIDE the org scope (D2 revised): it must work
#       from org-free pages (cockpit, user preferences) and for users without
#       any org — never bounce to the org picker. Still critical: no anonymous
#       access (unlike the public docs), no cross-surface leak (self-hosting
#       pages must 404 here), the login deep-link returns to the requested
#       page, and a silent language switch must announce itself (D9 banner).
RSpec.describe 'Help', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  # The first of the two example pages, and the one that carries the internal
  # link, the code block and the raw-HTML box.
  let(:first_slug) { 'guides/basics/erste-seite' }
  let(:second_slug) { 'guides/basics/zweite-seite' }

  let(:first_page_path) { help_page_path(slug: first_slug) }

  before { ActsAsTenant.current_tenant = organisation }

  def sign_in_as_member
    create(:membership, user: user, organisation: organisation, active: true)
    sign_in user
  end

  describe 'Authentifizierung' do
    it 'leitet anonyme Besucher zum Login und merkt sich die Zielseite' do
      get first_page_path

      expect(response).to redirect_to(new_user_session_path)
      expect(session['user_return_to']).to eq(first_page_path)
    end
  end

  describe 'Org-freie Erreichbarkeit (D2 revidiert)' do
    it 'rendert OHNE Session-Org (Cockpit-Fall) statt zum Org-Picker zu bouncen' do
      # load_tenant_from_session would redirect org-less sessions to the picker —
      # the help skips it; a regression here makes the cockpit help link dead.
      create(:membership, user: user, organisation: organisation, active: true)
      sign_in user

      get help_path(viewport: 'mobile')

      expect(response).to have_http_status(:ok)
    end

    it 'rendert für User ganz ohne Organisation' do
      sign_in user # no membership anywhere

      get help_path(viewport: 'mobile')

      expect(response).to have_http_status(:ok)
    end

    it 'stellt die Org-Shell wieder her, wenn die Session eine aktive Mitgliedschaft nennt' do
      sign_in_as_member
      # Entering an org page writes session[:current_organisation_id].
      get organisation_root_path(organisation_id: organisation.id)

      get first_page_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(organisation.name)
    end
  end

  describe 'Index' do
    before { sign_in_as_member }

    it 'leitet auf die erste Hilfe-Seite weiter (Desktop)' do
      get help_path

      # The order is the catalogue's, not one this app computes: the other
      # program writes the pages in the order its navigation shows them.
      expect(response).to redirect_to(help_page_path(slug: first_slug))
    end

    it 'zeigt mobil die Baum-Navigation statt einer Weiterleitung (DT7)' do
      get help_path(viewport: 'mobile')

      expect(response).to have_http_status(:ok)
      # Every page of the catalogue, not just the one being read.
      expect(response.body).to include(first_slug)
      expect(response.body).to include(second_slug)
      # The tree once had to prove it listed no self-hosting page. It cannot
      # reach one any more: the catalogue is written from Docs::Catalogue::AREAS
      # over in the documentation repository, and the spec there asserts the
      # self-hosting pages its own site serves stay OUT of the file. Repeating
      # the claim here would pass whatever that list said.
    end
  end

  describe 'Einzelseite' do
    before { sign_in_as_member }

    it 'rendert eine Hilfe-Seite im App-Layout mit Prose-Anker' do
      get first_page_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('help-page')
      expect(response.body).to include('help-prose')
      expect(response.body).to include('Erste Beispielseite')
    end

    it 'schreibt interne Links auf den org-gebundenen Hilfe-Pfad um' do
      get first_page_path

      # The example page carries exactly one internal link, to the second page,
      # and the catalogue holds it as the canonical /docs/de/... address.
      expect(response.body).to include(help_page_path(slug: second_slug))
      expect(response.body).not_to include("/docs/de/#{second_slug}")
    end

    it 'rendert den Seiteninhalt schlicht und stellt den Client-Highlight-Hook bereit' do
      get help_page_path(slug: first_slug, q: 'Platzhaltertext')

      expect(response).to have_http_status(:ok)
      # Highlighting now runs client-side (frame-search#highlightContent). No
      # server-side <mark>, but the prose selector is set as the hook.
      expect(response.body).not_to include('doc-search-hit')
      expect(response.body).to include('data-frame-search-highlight-selector-value=".help-prose"')
    end

    it 'behält die Vorschlagsliste gefüllt, wenn die Seite aus einem Treffer geöffnet wurde (?q=)' do
      # The result frame is pre-rendered server-side from ?q=, so the suggestions
      # survive the result click instead of vanishing. A result link carries q=,
      # which distinguishes it from the plain (q-less) navigation tree links.
      get help_page_path(slug: first_slug, q: 'Platzhaltertext')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(help_page_path(slug: second_slug, q: 'Platzhaltertext'))
      # The group is labelled with the hit count so it reads as search results.
      expect(response.body).to match(/\d+ Treffer/)
    end

    it 'rendert ohne Suche keine vorbefüllte Vorschlagsliste' do
      get first_page_path

      # The status first: a 404 carries no suggestion list either, so without
      # this line the example passes whenever the page is missing. Same trap as
      # the fallback banner below, found in review.
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to match(/#{Regexp.escape(second_slug)}\?q=/)
    end

    it 'liefert 404 für Seiten der Public-Surface (kein Cross-Surface-Leck)' do
      get help_page_path(slug: 'self-hosting/getting-started/overview')

      expect(response).to have_http_status(:not_found)
    end

    it 'liefert ein App-gestyltes 404 für unbekannte Slugs' do
      get help_page_path(slug: 'guides/gibt/es-nicht')

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include(I18n.t('views.organisations.help.not_found.title', locale: :de))
    end
  end

  describe 'Suche (D10)' do
    it 'verlangt Login (kein anonymer Zugriff auf den Such-Endpoint)' do
      get help_search_path(q: 'Projekt')

      expect(response).to redirect_to(new_user_session_path)
    end

    context 'als Mitglied' do
      before { sign_in_as_member }

      it 'liefert Treffer aus dem Katalog, verlinkt unter /hilfe' do
        # Searching a word from the pages' bodies rather than their titles: the
        # search must reach the text the catalogue carries, not just the index.
        get help_search_path(q: 'Platzhaltertext')

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('help-search-results')
        expect(response.body).to include('/hilfe/guides/')
        # That no OTHER area can appear here is pinned where the file is
        # written, not here -- see the note in the navigation example above.
      end

      it 'zeigt bei Treffern Links auf die org-gebundenen Hilfe-Seiten' do
        get help_search_path(q: 'Platzhaltertext')

        expect(response.body).to include(help_page_path(slug: second_slug))
      end

      it 'gibt den Suchbegriff an den Trefferlink weiter (fürs Highlight beim Öffnen)' do
        get help_search_path(q: 'Platzhaltertext')

        expect(response.body).to include(help_page_path(slug: second_slug, q: 'Platzhaltertext'))
      end

      it 'lässt den Frame unter der Mindestlänge leer' do
        get help_search_path(q: 'a')

        expect(response).to have_http_status(:ok)
        # Neither the empty-state message NOR results: a lowered length gate
        # would show hits here ("a" matches plenty of guides content).
        expect(response.body).not_to include(I18n.t('views.organisations.help.search.empty', locale: :de))
        expect(response.body).not_to include('/hilfe/guides/')
      end

      it 'zeigt den Leer-Zustand bei Suche ohne Treffer' do
        get help_search_path(q: 'Kubernetes-XYZ')

        expect(response.body).to include(I18n.t('views.organisations.help.search.empty', locale: :de))
      end
    end
  end

  describe 'Sanitize-Gate der Prose (Renderer-Emissionen müssen den Filter überleben)' do
    before do
      # The rendering happens in the other program now; this side only decides
      # what survives its sanitizer. So the example hands over the HTML that
      # renderer emits, rather than markdown for a renderer this app no longer
      # has: code block with its copy button and Rouge spans, a callout, a
      # table, and a script tag that MUST be stripped.
      write_docs_catalogue(
        de: [docs_catalogue_page(
          slug: first_slug, title: 'Erstes Projekt',
          html: <<~HTML
            <h1 id="erstes-projekt">Erstes Projekt</h1>
            <div class="docs-codeblock">
              <button type="button" class="docs-codeblock__copy" aria-label="#{I18n.t('docs.chrome.copy', locale: :de)}"></button>
              <pre class="highlight"><code><span class="nb">echo</span> <span class="s2">"hallo"</span></code></pre>
            </div>
            <div class="docs-callout docs-callout--info">
              <div class="docs-callout__title">Hinweis</div>
              <p>Callout-Inhalt.</p>
            </div>
            <table><thead><tr><th>Spalte A</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>
            <script>alert('xss')</script>
          HTML
        )]
      )

      sign_in_as_member
    end

    it 'behält Copy-Button (aria-label), Content-Klassen, Rouge-Spans und Tabellen' do
      get first_page_path

      expect(response.body).to include('docs-codeblock__copy')
      expect(response.body).to include(%(aria-label="#{I18n.t('docs.chrome.copy', locale: :de)}"))
      expect(response.body).to include('docs-callout--info')
      expect(response.body).to match(%r{<span class="[^"]*"[^>]*>echo</span>|<span class="nb">echo})
      expect(response.body).to include('<td>1</td>')
    end

    it 'strippt Script-Tags aus dem Content (Defense in Depth)' do
      get first_page_path

      expect(response.body).not_to include('<script>alert')
    end

    # Derived from the constant, not from a list retyped here: what the contract
    # allows is what has to survive the view. The recorded catalogue is a
    # two-page example and uses fifteen tags; the handbook also uses `ul`, `ol`,
    # `li`, `strong`, `em` and `h3`, thousands of times, and none of them passed
    # through any spec. A view sanitizing with a narrower list than the contract
    # would have emptied every list on every help page with nothing turning red.
    # Measured: pinning the view to %w[p a h1 h2] reports nineteen dropped tags.
    #
    # ⚠️ What this CANNOT see, because it reads the same constant the view does:
    # a tag REMOVED from ALLOWED_TAGS. The loop then stops asking about it. That
    # is the price of deriving instead of retyping, and it is the right trade
    # here: a shrinking allowlist is a deliberate edit somebody makes on purpose,
    # a drifting view is an accident.
    it 'lässt JEDES erlaubte Tag durch, nicht nur die des Beispiels' do
      write_docs_catalogue(de: [docs_catalogue_page(slug: first_slug, title: 'Alles',
                                                    html: every_allowed_tag)])

      get first_page_path

      expect(response).to have_http_status(:ok)
      dropped = Docs::Contract::ALLOWED_TAGS.reject do |tag|
        response.body.include?("<#{tag}")
      end

      expect(dropped).to be_empty, "the view dropped: #{dropped.join(', ')}"
    end
  end

  # One valid document holding every tag Docs::Contract allows, nested the way
  # the tags require (a `li` needs its list, a `td` its row).
  def every_allowed_tag
    <<~HTML
      <h1 id="a">H1</h1><h2 id="b">H2</h2><h3 id="c">H3</h3>
      <h4>H4</h4><h5>H5</h5><h6>H6</h6>
      <p>Text with <strong>bold</strong>, <em>italic</em>, <del>struck</del>,
        <code>code</code>, <span class="x">span</span>, <br>
        <a href="/docs/de/guides/basics/zweite-seite">a link</a> and
        <img src="/x.png" alt="an image">.</p>
      <div class="docs-callout"><blockquote>Quoted.</blockquote></div>
      <ul><li>Unordered item</li></ul>
      <ol><li>Ordered item</li></ol>
      <pre><code>code block</code></pre>
      <button type="button" aria-label="Kopieren"></button>
      <hr>
      <table><thead><tr><th>Head</th></tr></thead><tbody><tr><td>Cell</td></tr></tbody></table>
    HTML
  end

  describe 'EN→DE-Fallback-Banner (D9)' do
    before do
      # A page the English catalogue does not have. The fallback crosses FILES
      # now, where it used to cross directories.
      write_docs_catalogue(
        de: [docs_catalogue_page(slug: first_slug, title: 'Erstes Projekt')],
        en: []
      )

      user.update!(language_preference: 'en')
      sign_in_as_member
    end

    after do
      # The EN request set the thread locale; reset it so later specs (which
      # assert against the ambient locale) don't inherit :en.
      I18n.locale = I18n.default_locale
    end

    it 'zeigt den Hinweis-Banner, wenn die Seite nur auf Deutsch existiert' do
      get first_page_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.organisations.help.show.fallback_notice', locale: :en))
    end

    it 'zeigt KEINEN Banner, wenn die Seite in der Sprache des Users existiert' do
      write_docs_catalogue(
        de: [docs_catalogue_page(slug: first_slug, title: 'Erstes Projekt')],
        en: [docs_catalogue_page(slug: first_slug, title: 'First project',
                                 section_title: 'Basics')]
      )

      get first_page_path

      # The status matters here: an absent page answers 404, and a 404 carries
      # no banner either. Without this line the example passed while the page
      # it is about did not exist.
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t('views.organisations.help.show.fallback_notice', locale: :en))
    end
  end
end
