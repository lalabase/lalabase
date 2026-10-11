# frozen_string_literal: true

require 'rails_helper'

# What: Docs::PageLinks -- which docs page a link written in a page addresses.
# Type: Unit spec.
# Why:  Two readers resolve the same links: the renderer (to canonical hrefs) and the
#       assistant's get_help_page (to slugs a model can read on). If they disagreed, the page a
#       reader clicks and the page the model reads would be two different pages.
RSpec.describe Docs::PageLinks do
  def target(link, base: 'guides/basics/tickets')
    described_class.target(link, base_slug: base)
  end

  it 'resolves a link relative to the directory of the page' do
    expect(target('first-project')).to eq(['guides/basics/first-project', nil])
    expect(target('./first-project')).to eq(['guides/basics/first-project', nil])
    expect(target('../ticket-views/assign-status#status')).to eq(['guides/ticket-views/assign-status', '#status'])
  end

  it 'reads the canonical form, whatever its language segment' do
    expect(target('/docs/en/guides/team/invite-members/#roles')).to eq(['guides/team/invite-members', '#roles'])
  end

  it 'answers nil for everything that addresses no docs page' do
    ['https://example.com', 'mailto:a@example.com', '//cdn.example.com/x', '#status', '/pricing', '', nil].each do |link|
      expect(target(link)).to be_nil, link.inspect
    end
  end

  # `.cross_surface?` went with D5, and it has no successor anywhere: the notion of
  # two surfaces was this application serving the handbook and the self-hosting
  # docs from ONE tree behind two different gates. The documentation program
  # serves every page publicly, so its renderer links them all and never asks the
  # question (checked: neither `cross_surface?` nor `Surfaces` exists over there).
  #
  # The canonical shape both sides must agree on is Docs::Contract's, which this
  # module now reads instead of keeping its own copy.
  it 'reads the canonical shape from the contract, not from a second copy' do
    expect(described_class.const_defined?(:CANONICAL_DOCS_REGEX, false)).to be(false)
    expect(target('/docs/de/guides/basics/tickets')).to eq(['guides/basics/tickets', nil])
  end
end
