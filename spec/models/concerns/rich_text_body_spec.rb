# frozen_string_literal: true

require 'rails_helper'

# What: a model with a rich text body keeps a plain text mirror of it in two columns,
#   plain_text_version and plain_text_word_count, written before every save.
# Why: lists, excerpts and counters read the mirror instead of parsing the rich text.
#   The examples hold what the mirror does for every carrier alike, so the code can
#   have one owner and a new carrier joins by one line below.
#
# A group that includes the shared examples defines two things:
#   carrier_with(html)  a saved record whose body is the given HTML
#   unrelated_change    attributes that change the record and leave its body alone
RSpec.shared_examples 'a carrier of the plain text mirror' do
  it 'mirrors the plain text of the body and counts its words when the record is created' do
    carrier = carrier_with('<p>Guten <strong>Morgen</strong> zusammen</p>').reload

    expect(carrier.plain_text_version).to eq('Guten Morgen zusammen')
    expect(carrier.plain_text_word_count).to eq(3)
  end

  it 'follows the body when it changes' do
    carrier = carrier_with('<p>Guten Morgen zusammen</p>')

    carrier.update!(content: '<p>Jetzt stehen hier fünf Wörter</p>')

    expect(carrier.reload.plain_text_version).to eq('Jetzt stehen hier fünf Wörter')
    expect(carrier.plain_text_word_count).to eq(5)
  end

  it 'leaves both as they were on a save that does not touch the body' do
    carrier = carrier_with('<p>Guten Morgen zusammen</p>')

    carrier.class.find(carrier.id).update!(unrelated_change)

    expect(carrier.reload).to have_attributes(unrelated_change)
    expect(carrier.plain_text_version).to eq('Guten Morgen zusammen')
    expect(carrier.plain_text_word_count).to eq(3)
  end

  # The plain text keeps the blanks of the body: before the first word, between two
  # words, and a line break between two blocks. The count is of the words.
  it 'counts the words, not the blanks between and around them' do
    carrier = carrier_with('<div>  Eins   zwei</div><div>drei   </div>').reload

    expect(carrier.plain_text_version).to eq("  Eins   zwei\ndrei   ")
    expect(carrier.plain_text_word_count).to eq(3)
  end

  # Reachable only past the validations. The mirror is then an empty text, not nil.
  it 'mirrors an empty text and no word for a record saved without a body' do
    carrier = carrier_with('<p>Guten Morgen zusammen</p>')

    carrier.content = nil
    carrier.save!(validate: false)

    expect(carrier.reload.plain_text_version).to eq('')
    expect(carrier.plain_text_word_count).to eq(0)
  end
end

RSpec.describe 'The plain text mirror of a rich text body', :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:author) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe Post do
    let(:ticket) { create(:ticket, project: project, organisation: organisation) }
    let(:unrelated_change) { { create_embeddings: false } }

    def carrier_with(html)
      create(:post, ticket: ticket, organisation: organisation, user: author, content: html)
    end

    it_behaves_like 'a carrier of the plain text mirror'
  end

  describe Note do
    let(:unrelated_change) { { title: 'Ein anderer Titel' } }

    def carrier_with(html)
      create(:note, project: project, organisation: organisation, creator: author, content: html)
    end

    it_behaves_like 'a carrier of the plain text mirror'
  end
end
