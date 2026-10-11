# frozen_string_literal: true

# == Schema Information
#
# Table name: documentation_pages
#
#  id                       :uuid             not null, primary key
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  git_blob_sha             :string           not null
#  markdown_body            :text
#  path                     :string           not null
#  removed_at               :datetime
#  rendered_html            :text
#  title                    :string
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  documentation_set_id     :uuid             not null
#  organisation_id          :uuid             not null
#
# Indexes
#
#  idx_documentation_pages_set_path                   (documentation_set_id,path) UNIQUE
#  idx_on_documentation_set_id_removed_at_c6f42b1828  (documentation_set_id,removed_at)
#  index_documentation_pages_on_documentation_set_id  (documentation_set_id)
#  index_documentation_pages_on_organisation_id       (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (documentation_set_id => documentation_sets.id)
#  fk_rails_...  (organisation_id => organisations.id)
#
require 'rails_helper'

# What: DocumentationPage — validations, present/removed scoping, tenant
#       isolation.
# Type: Model spec.
# Why:  Pages are the synced .md files; a removed source file must stop
#       surfacing without a hard delete (soft-removal), scoped per set + tenant.
RSpec.describe DocumentationPage, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:set) { create(:documentation_set, project: create(:project, organisation: organisation)) }

  before { ActsAsTenant.current_tenant = organisation }

  describe 'validations' do
    it 'is valid with the factory' do
      expect(build(:documentation_page, documentation_set: set)).to be_valid
    end

    it 'requires a path' do
      expect(build(:documentation_page, documentation_set: set, path: nil)).not_to be_valid
    end

    it 'requires a git_blob_sha' do
      expect(build(:documentation_page, documentation_set: set, git_blob_sha: nil)).not_to be_valid
    end

    it 'enforces a unique path per set' do
      create(:documentation_page, documentation_set: set, path: 'a/b.md')
      expect(build(:documentation_page, documentation_set: set, path: 'a/b.md')).not_to be_valid
    end

    it 'allows the same path in a different set' do
      create(:documentation_page, documentation_set: set, path: 'a/b.md')
      other_set = create(:documentation_set, project: create(:project, organisation: organisation))
      expect(build(:documentation_page, documentation_set: other_set, path: 'a/b.md')).to be_valid
    end
  end

  # Defense in depth: the (documentation_set_id, path) unique index must hold even
  # if the model validation is bypassed.
  describe 'DB-level path uniqueness' do
    it 'raises RecordNotUnique when the model validation is skipped' do
      create(:documentation_page, documentation_set: set, path: 'a/b.md')
      dup = build(:documentation_page, documentation_set: set, path: 'a/b.md')
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'scopes' do
    it 'present_pages excludes removed pages' do
      live = create(:documentation_page, documentation_set: set)
      create(:documentation_page, documentation_set: set, removed_at: Time.current)
      expect(DocumentationPage.present_pages).to contain_exactly(live)
    end
  end

  describe '.search_text' do
    it 'matches on the title' do
      hit = create(:documentation_page, documentation_set: set, title: 'Alpha Guide', markdown_body: 'x')
      create(:documentation_page, documentation_set: set, title: 'Beta Notes', markdown_body: 'y')

      expect(DocumentationPage.search_text('Alpha')).to contain_exactly(hit)
    end

    it 'matches on the markdown body' do
      hit = create(:documentation_page, documentation_set: set, title: 'A', markdown_body: 'deploy via capistrano')
      create(:documentation_page, documentation_set: set, title: 'B', markdown_body: 'unrelated')

      expect(DocumentationPage.search_text('capistrano')).to contain_exactly(hit)
    end

    it 'is case-insensitive' do
      hit = create(:documentation_page, documentation_set: set, title: 'Alpha Guide')

      expect(DocumentationPage.search_text('alpha')).to contain_exactly(hit)
    end

    it 'treats LIKE wildcards in the query as literal characters' do
      hit = create(:documentation_page, documentation_set: set, title: 'A', markdown_body: 'covers 100% of cases')
      # Without escaping, "100%" would also match this page ("100" + anything).
      create(:documentation_page, documentation_set: set, title: 'B', markdown_body: '100 reasons')

      expect(DocumentationPage.search_text('100%')).to contain_exactly(hit)
    end
  end

  describe '#removed?' do
    it 'reflects removed_at' do
      expect(build(:documentation_page, removed_at: Time.current)).to be_removed
      expect(build(:documentation_page, removed_at: nil)).not_to be_removed
    end
  end

  describe 'tenant isolation' do
    it 'scopes pages to the tenant' do
      create(:documentation_page, documentation_set: set)
      ActsAsTenant.with_tenant(other_organisation) { expect(DocumentationPage.count).to eq(0) }
      expect(DocumentationPage.count).to eq(1)
    end
  end

  # Insert-defaults as a contract: a freshly synced page is "pending" — the
  # migration adds both columns with NO default, so the reprocessing backfill
  # (flag IS NULL) picks it up. Pinned WITHOUT setting the flag in the factory.
  describe 'embedding bookkeeping defaults' do
    it 'defaults embeddings_creation_flag and embedding_creation_error to nil (pending)' do
      page = create(:documentation_page, documentation_set: set).reload
      expect(page.embeddings_creation_flag).to be_nil
      expect(page.embedding_creation_error).to be_nil
    end
  end

  # The EmbeddingProcessingService contract (Slice 3): plain_text_version is what
  # gets chunked and embedded. It must strip markdown SYNTAX so the vector carries
  # meaning, not #/*/link noise.
  describe '#plain_text_version' do
    def plain_text_for(markdown)
      build(:documentation_page, documentation_set: set, markdown_body: markdown).plain_text_version
    end

    it 'strips heading, emphasis and code markers, keeping the words' do
      text = plain_text_for("# Deploy Guide\n\nRun **cap** and `bin/setup`.")
      expect(text).to include('Deploy Guide', 'Run', 'cap', 'bin/setup')
      expect(text).not_to include('#', '**', '`')
    end

    it 'keeps the link text (and url) but drops the markdown link syntax' do
      text = plain_text_for('See [the runbook](https://example.com/run).')
      expect(text).to include('the runbook')
      expect(text).not_to include('[the runbook]')
    end

    it 'returns an empty string for a blank body (service then skips the page)' do
      expect(plain_text_for(nil)).to eq('')
      expect(plain_text_for('')).to eq('')
    end
  end

  # Fragment cleanup is the load-bearing invariant of Slice 3: gone docs must stop
  # grounding chat. Fragments are polymorphic (no DB FK), so removal is our job.
  describe 'fragment ownership' do
    let(:page) { create(:documentation_page, documentation_set: set) }

    it 'destroys its fragments when the page itself is destroyed (direct path)' do
      fragment = create(:fragment, fragmentable: page, organisation: organisation)
      expect { page.destroy }.to change { Fragment.where(id: fragment.id).count }.from(1).to(0)
    end

    describe '.purge_fragments_for' do
      it 'deletes fragments of the given pages and leaves others untouched' do
        other_page = create(:documentation_page, documentation_set: set)
        purged = create(:fragment, fragmentable: page, organisation: organisation)
        kept   = create(:fragment, fragmentable: other_page, organisation: organisation)

        DocumentationPage.purge_fragments_for([page.id])

        expect(Fragment.where(id: purged.id)).to be_empty
        expect(Fragment.where(id: kept.id)).to be_present
      end

      it 'accepts a relation (subquery) as well as an array of ids' do
        create(:fragment, fragmentable: page, organisation: organisation)
        expect { DocumentationPage.purge_fragments_for(set.documentation_pages.select(:id)) }
          .to change(Fragment, :count).by(-1)
      end

      it 'never touches a fragment of a different fragmentable type with the same id space' do
        # A note whose id happens to collide would be a disaster; the type filter
        # must be part of the delete. Same-org note fragment must survive.
        note = create(:note, project: set.project, organisation: organisation)
        note_fragment = create(:fragment, fragmentable: note, organisation: organisation)

        DocumentationPage.purge_fragments_for([page.id, note.id])

        expect(Fragment.where(id: note_fragment.id)).to be_present
      end

      it 'is a no-op for an empty array (WHERE 1=0, no accidental full delete)' do
        create(:fragment, fragmentable: page, organisation: organisation)
        expect { DocumentationPage.purge_fragments_for([]) }.not_to change(Fragment, :count)
      end
    end
  end

  # Slice 4: a page OWNS its outgoing Reference rows (it is the link source). Same
  # dual-cleanup shape as fragments — direct destroy via dependent:, the two bulk
  # paths via .purge_references_for.
  describe 'outgoing reference ownership' do
    let(:page) { create(:documentation_page, documentation_set: set) }
    let(:target_note) { create(:note, project: set.project, organisation: organisation) }

    def link(from_page, to_target)
      Reference.create!(source: from_page, target: to_target, target_title_snapshot: 'T')
    end

    it 'destroys its outgoing references when the page itself is destroyed (direct path)' do
      ref = link(page, target_note)
      expect { page.destroy }.to change { Reference.where(id: ref.id).count }.from(1).to(0)
    end

    describe '.purge_references_for' do
      it 'deletes references of the given pages and leaves others untouched' do
        other_page = create(:documentation_page, documentation_set: set)
        purged = link(page, target_note)
        kept   = link(other_page, target_note)

        DocumentationPage.purge_references_for([page.id])

        expect(Reference.where(id: purged.id)).to be_empty
        expect(Reference.where(id: kept.id)).to be_present
      end

      it 'never touches a reference from a different source type with the same id space' do
        # A note whose id collides with a page id must keep ITS outgoing reference:
        # the source_type filter has to be part of the delete.
        note = create(:note, project: set.project, organisation: organisation)
        note_ref = Reference.create!(source: note, target: target_note, target_title_snapshot: 'N')

        DocumentationPage.purge_references_for([page.id, note.id])

        expect(Reference.where(id: note_ref.id)).to be_present
      end

      it 'is a no-op for an empty array (WHERE 1=0, no accidental full delete)' do
        link(page, target_note)
        expect { DocumentationPage.purge_references_for([]) }.not_to change(Reference, :count)
      end
    end
  end
end
