# frozen_string_literal: true

require 'rails_helper'

# What:  Reference — polymorphic link index (note → note | document), D3.
# Type:  Model spec (DB), tenant-scoped.
# Why:   The link graph carries backlinks, tombstones and (later, via policy_scope)
#        the access display. We test the hard decision points: self-reference
#        forbidden, DB unique as dedup, tombstone on a deleted target, polymorphic
#        targets, tenant isolation.
RSpec.describe Reference, type: :model do
  let(:organisation)       { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  let(:source_note) { create(:note, organisation: organisation) }
  let(:target_note) { create(:note, organisation: organisation) }

  def link(source, target, title: 'Target')
    Reference.create!(source: source, target: target, target_title_snapshot: title)
  end

  describe 'self-reference' do
    it 'forbids a reference pointing to itself' do
      ref = Reference.new(source: source_note, target: source_note)
      expect(ref).not_to be_valid
      expect(ref.errors[:base]).to be_present
    end

    it 'allows a reference to a different note' do
      expect { link(source_note, target_note) }.to change(Reference, :count).by(1)
    end
  end

  describe 'DB unique (dedup)' do
    # Intent: the same source→target combination can exist only once — the DB index
    # is the real guard (matching the delete+insert rebuild).
    it 'rejects the same source→target combination a second time' do
      link(source_note, target_note)
      expect { link(source_note, target_note) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'polymorphic targets' do
    it 'can point to a note and to a document' do
      document = create(:document, organisation: organisation)
      expect { link(source_note, target_note) }.to change(Reference, :count).by(1)
      expect { link(source_note, document) }.to change(Reference, :count).by(1)
    end
  end

  describe 'tombstone on a deleted target' do
    # Intent: when the target is hard-deleted, the reference row + snapshot remain
    # (displays "points to a deleted page" instead of a 404).
    it 'survives the hard-delete of the target and keeps the title snapshot' do
      ref = link(source_note, target_note, title: 'Old title')
      target_note.destroy!

      ref.reload
      expect(ref.target).to be_nil
      expect(ref.target_title_snapshot).to eq('Old title')
      expect(Reference.pointing_to(target_note)).to include(ref)
    end
  end

  describe '.pointing_to (backlinks)' do
    it 'finds references that point to a record' do
      ref = link(source_note, target_note)
      other = create(:note, organisation: organisation)
      link(source_note, other)

      expect(Reference.pointing_to(target_note)).to contain_exactly(ref)
    end
  end

  describe 'tenant isolation' do
    it 'does not show references of one org under another' do
      link(source_note, target_note)
      ActsAsTenant.with_tenant(other_organisation) do
        expect(Reference.count).to eq(0)
      end
      expect(Reference.count).to eq(1)
    end
  end

  describe 'cascade from the source' do
    # Mutation guard: removing `dependent: :destroy` on Note#outgoing_references turns
    # this red (the orphan reference survives, count unchanged). Contrast with the
    # tombstone case above: deleting the TARGET keeps the reference, deleting the
    # SOURCE removes it.
    it 'is destroyed when its source note is destroyed' do
      link(source_note, target_note)
      # reload: the reference was inserted out-of-band, so the note's cached
      # outgoing_references is stale; reload lets dependent: :destroy see it.
      expect { source_note.reload.destroy! }.to change(Reference, :count).by(-1)
    end
  end

  describe 'composite unique key boundary' do
    # Mutation guard: dropping target_type from the unique index turns this red,
    # because the same source+target_id under a different type would then collide.
    it 'allows the same source+target_id under a different target_type' do
      shared_id = SecureRandom.uuid
      Reference.create!(source: source_note, target_type: 'Note', target_id: shared_id, target_title_snapshot: 'a')
      dup = Reference.new(source: source_note, target_type: 'Document', target_id: shared_id, target_title_snapshot: 'b')

      expect { dup.save! }.not_to raise_error
    end
  end

  describe 'documentation page as source (Slice 4)' do
    let(:page) do
      set = create(:documentation_set, project: create(:project, organisation: organisation))
      create(:documentation_page, documentation_set: set)
    end

    it 'links a documentation page to a note (new source_type is accepted)' do
      ref = Reference.create!(source: page, target: target_note, target_title_snapshot: 'Runbook')
      expect(ref.source_type).to eq('DocumentationPage')
      expect(ref.target).to eq(target_note)
    end

    it 'never trips the self-reference guard (a page can only ever be a source)' do
      # source_type 'DocumentationPage' can never equal a Note/Document target type,
      # so forbid_self_reference cannot fire. Locks that assumption in.
      ref = Reference.new(source: page, target: target_note)
      expect(ref).to be_valid
    end

    it 'relies on the DB unique index for dedup even past validations (defense in depth)' do
      # validate: false skips any model-level guard, proving the real dedup is the DB
      # unique index (source_type, source_id, target_type, target_id) — what the sync
      # job's delete+insert rebuild leans on.
      Reference.create!(source: page, target: target_note, target_title_snapshot: 'a')
      dup = Reference.new(source: page, target: target_note, target_title_snapshot: 'b')
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'target_title_snapshot length (boundary)' do
    it 'accepts exactly 255 characters' do
      ref = Reference.new(source: source_note, target: target_note, target_title_snapshot: 'x' * 255)
      expect(ref).to be_valid
    end

    it 'rejects 256 characters' do
      ref = Reference.new(source: source_note, target: target_note, target_title_snapshot: 'x' * 256)
      expect(ref).not_to be_valid
    end
  end
end
