# frozen_string_literal: true

require 'rails_helper'

# What:  Wiki::MentionResolver — signed GlobalID (sgid) → record / display info.
# Type:  Unit spec (DB, since real signed GlobalIDs are resolved).
# Why:   Tested on its own because resolution (DB/GlobalID) is a different concern
#        than serialization — and the reference rebuild builds on record_for.
#        Contracts: a real ActionText mention sgid (attachable PURPOSE) → hit; anything
#        invalid → nil (so a deleted/forged target does not blow up the save).
# Note:  Mention sgids are the ones ActionText/Lexxy mint — record.attachable_sgid,
#        signed with the "attachable" purpose. A default-purpose to_sgid would NOT
#        resolve here, which is exactly why record_for goes through from_attachable_sgid.
RSpec.describe Wiki::MentionResolver do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  subject(:resolver) { described_class.new }

  describe '#record_for' do
    it 'resolves a mention (attachable) sgid to the record' do
      note = create(:note, organisation: organisation)
      expect(resolver.record_for(note.attachable_sgid)).to eq(note)
    end

    it 'does NOT resolve a default-purpose sgid (mentions are attachable-purpose only)' do
      note = create(:note, organisation: organisation)
      expect(resolver.record_for(note.to_signed_global_id.to_s)).to be_nil
    end

    it 'returns nil for blank or unresolvable sgids' do
      expect(resolver.record_for(nil)).to be_nil
      expect(resolver.record_for('')).to be_nil
      expect(resolver.record_for('not-a-valid-sgid')).to be_nil
    end

    # Mutation guard: the above inputs make the locator RETURN nil — they do NOT exercise
    # the `rescue StandardError` clause (removing it would keep them green). A malformed
    # sgid that makes the locator RAISE (e.g. an unknown model class) must still degrade
    # to nil so a note save/render never crashes. Stubbing the raise pins exactly that.
    it 'swallows an exception from the locator and returns nil' do
      allow(GlobalID::Locator).to receive(:locate_signed).and_raise(StandardError, 'boom')
      expect(resolver.record_for('anything')).to be_nil
    end
  end

  describe '#call' do
    it 'returns compact display info (type/id/title) for the serializer link' do
      note = create(:note, organisation: organisation, title: 'Target note')

      expect(resolver.call(note.attachable_sgid))
        .to eq(type: 'note', id: note.id, title: 'Target note')
    end

    it 'returns nil for an unresolvable target' do
      expect(resolver.call('gone')).to be_nil
    end
  end
end
