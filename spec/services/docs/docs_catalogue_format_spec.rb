# frozen_string_literal: true

require 'rails_helper'

# What: the catalogue the specs BUILD carries the same shape as the one the
#       other program WRITES.
#
# Why:  spec/fixtures/docs_catalogue holds a file written by
#       gboyke/lalabase-documentation, by the SAME builder that writes the
#       handbook's catalogue in production (`rake catalogue:example`, over two
#       invented pages). The builder in spec/support assembles the format by
#       hand for cases that file cannot cover, and a hand-assembled format
#       drifts. Drift here does not fail: it passes, while the help reads
#       something production never sends.
#
#       The recording is an example rather than the handbook because the
#       handbook's text must not live in this repository at all
#       (doc/docs_delivery_plan.md, goal 1). That costs nothing here: what this
#       file compares is shape, and shape does not care how many pages there
#       are.
RSpec.describe 'the catalogue format' do
  let(:recorded) do
    JSON.parse(Rails.root.join('spec/fixtures/docs_catalogue/docs_catalogue.de.json').read,
               symbolize_names: true)
  end

  let(:built) do
    docs_catalogue_document('de', [docs_catalogue_page(slug: 'guides/basics/x', title: 'X')])
  end

  it 'has a recording that the other program wrote, with pages in it' do
    expect(recorded[:pages]).not_to be_empty
    expect(recorded[:format_version]).to eq(Docs::Catalogue::SUPPORTED_FORMAT)

    # Every page carries content in every field the reader projects. A recording
    # with empty bodies would satisfy the key comparisons below while the help
    # showed blank pages.
    recorded[:pages].each do |page|
      # :description included: the assistant's contents list is built from it, and
      # a page without one cannot be chosen by meaning.
      expect(page.values_at(:slug, :title, :section, :section_title, :description,
                            :html, :markdown, :text))
        .to all(be_present)
    end

    # Written by a program, not by hand here: the writer stamps which commit of
    # the documentation repository the file came from.
    expect(recorded[:source_version]).to be_present
  end

  it 'agrees on the top-level keys' do
    expect(built.keys.sort).to eq(recorded.keys.sort)
  end

  it 'agrees on the page keys' do
    expect(built[:pages].first.keys.sort).to eq(recorded[:pages].first.keys.sort)
  end

  # The canonical `/docs/<locale>/<slug>` shape exists TWICE, once per repository:
  # Docs::Contract here, Docs::PageLinks::CANONICAL_DOCS_REGEX over there. No
  # shared library keeps them in step, and a divergence would not raise: the
  # rewriter would simply stop recognising the links in the HTML, and every
  # internal link on every help page would turn into a link into the public
  # documentation. Which works, and is wrong.
  #
  # So the recording is the check. These are the links the other program really
  # wrote, and this side has to resolve every one of them.
  it 'writes internal links in the shape this side resolves' do
    hrefs = recorded[:pages].flat_map { |page| page[:html].to_s.scan(/href="([^"]*)"/).flatten }
    internal = hrefs.select { |href| href.start_with?('/docs/') }

    expect(internal).not_to be_empty, 'the recorded example carries no internal link to check'
    internal.each do |href|
      expect(href).to match(Docs::Contract::CANONICAL_DOCS_REGEX), href
      expect(Docs::PageLinks.target(href, base_slug: 'guides/basics/erste-seite')).to be_present
    end
  end

  it 'agrees on the group and item keys' do
    expect(built[:groups].first.keys.sort).to eq(recorded[:groups].first.keys.sort)
    expect(built[:groups].first[:items].first.keys.sort)
      .to eq(recorded[:groups].first[:items].first.keys.sort)
  end
end
