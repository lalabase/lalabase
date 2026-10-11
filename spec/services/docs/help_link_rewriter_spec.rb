# frozen_string_literal: true

require 'rails_helper'

# What:  Docs::HelpLinkRewriter — request-time rewrite of the canonical
#        /docs/<locale>/<slug> hrefs the catalogue's HTML carries.
# Type:  Service-/unit-test on HTML strings.
# Why:   Help paths carry the organisation id, so they cannot be baked into a
#        catalogue that knows no organisation. THREE cases since the
#        documentation became a public site of its own: a page this instance has
#        goes to the help path, a page it does not have goes to the public
#        documentation, and anything else is left alone. The middle case used to
#        be unlinked, because the other surface was gated and the link was dead;
#        it points at a readable page now.
RSpec.describe Docs::HelpLinkRewriter do
  let(:base_path) { '/org/0af1/hilfe' }

  # A catalogue holding exactly one page, so "in the catalogue" and "not in it"
  # are both reachable in an example.
  let(:catalogue) do
    write_docs_catalogue(de: [docs_catalogue_page(slug: 'guides/basics/tickets', title: 'Tickets')])
    Docs::Catalogue.for('de')
  end

  def rewrite(html, locale: 'de')
    described_class.rewrite(html, base_path: base_path, catalogue: catalogue, locale: locale)
  end

  it 'schreibt kanonische Docs-Links auf den Hilfe-Basis-Pfad um (Locale entfällt)' do
    html = rewrite('<a href="/docs/de/guides/basics/tickets">Tickets</a>')
    expect(html).to include(%(href="#{base_path}/guides/basics/tickets"))
  end

  it 'behält Anker beim Umschreiben bei' do
    html = rewrite('<a href="/docs/en/guides/basics/tickets#status">Tickets</a>')
    expect(html).to include(%(href="#{base_path}/guides/basics/tickets#status"))
  end

  it 'verlinkt eine Seite, die diese Instanz nicht hat, in die öffentliche Doku' do
    html = rewrite('<p>Siehe <a href="/docs/de/self-hosting/configuration/ai-byok">KI-Schlüssel</a>.</p>')

    expect(html).to include('href="https://lalabase.com/docs/de/self-hosting/configuration/ai-byok"')
    expect(html).to include('KI-Schlüssel')
  end

  it 'nimmt für den öffentlichen Link die Sprache des Lesers mit' do
    html = rewrite('<a href="/docs/de/self-hosting/configuration/ai-byok">Key</a>', locale: 'en')

    expect(html).to include('href="https://lalabase.com/docs/en/self-hosting/configuration/ai-byok"')
  end

  it 'behält den Anker auch beim öffentlichen Link' do
    html = rewrite('<a href="/docs/de/self-hosting/installation/docker#ports">Ports</a>')

    expect(html).to include('href="https://lalabase.com/docs/de/self-hosting/installation/docker#ports"')
  end

  it 'lässt externe Links unverändert' do
    html = rewrite('<a href="https://lalabase.de">Homepage</a>')
    expect(html).to include('href="https://lalabase.de"')
  end

  it 'lässt reine Anker-Links unverändert' do
    html = rewrite('<a href="#setup">Abschnitt</a>')
    expect(html).to include('href="#setup"')
  end

  it 'lässt Nicht-Link-Markup unangetastet (Codeblöcke, Buttons)' do
    input = '<div class="docs-codeblock"><button type="button" class="docs-codeblock__copy" aria-label="Kopieren"></button><pre class="highlight"><code>x</code></pre></div>'
    expect(rewrite(input)).to include('docs-codeblock__copy')
  end
end
