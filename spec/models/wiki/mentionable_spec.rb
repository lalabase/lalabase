# frozen_string_literal: true

require 'rails_helper'

# What:  Wiki::Mentionable — the shared concern that makes Note/Document linkable as
#        @-mentions (ActionText::Attachable + a mention render partial).
# Type:  Model concern spec.
# Why:   These three values are the contract the whole mention chain hangs on:
#        - to_attachable_partial_path decides which partial renders a stored mention,
#        - attachable_content_type marks the attachment as a mention so the serializer/
#          extractor detect it,
#        - attachable_plain_text_representation feeds plain_text / search.
#        They are defined via PREPEND specifically to win the ancestor race against
#        ActionText::Attachable's defaults (a plain include lost it — verified). If that
#        regresses, these break — so we pin them per host model.
RSpec.describe Wiki::Mentionable do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  describe '#to_attachable_partial_path (override must win over ActionText::Attachable)' do
    it 'derives a per-model mention partial path' do
      expect(Note.new.to_attachable_partial_path).to eq('organisations/notes/mention')
      expect(Document.new.to_attachable_partial_path).to eq('organisations/documents/mention')
    end
  end

  describe '#attachable_content_type' do
    # Mutation guard: changing the suffix/type would make Wiki::Mention.nodes stop detecting
    # the attachment, so the serializer would no longer turn it into a lalabase: link.
    it 'marks the attachment as a wiki mention' do
      expect(Note.new.attachable_content_type).to eq('application/vnd.actiontext.mention')
      expect(Note.new.attachable_content_type).to end_with(Wiki::Mention::CONTENT_TYPE_SUFFIX)
    end
  end

  describe '#attachable_plain_text_representation' do
    it 'is the title, so a mention still contributes searchable text' do
      note = Note.new(title: 'Plain Title')
      expect(note.attachable_plain_text_representation).to eq('Plain Title')
    end
  end

  describe 'ActionText::Attachable wiring' do
    # Bonus: proves the concern actually pulled Attachable in (attachable_sgid exists and is
    # the attachable-purpose sgid the picker mints and MentionResolver resolves).
    it 'exposes an attachable_sgid' do
      note = create(:note, organisation: organisation)
      expect(note.attachable_sgid).to be_present
      expect(GlobalID::Locator.locate_signed(note.attachable_sgid, for: 'attachable')).to eq(note)
    end
  end
end
