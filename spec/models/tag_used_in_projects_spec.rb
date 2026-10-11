# frozen_string_literal: true

require 'rails_helper'

# R1 regression guard: Tags must be scopeable to the projects they are actually used
# in (via taggings on Note/Document/Ticket), so the tag list / autocomplete cannot leak
# foreign-project tag names. No project_id on Tag — the scope goes through taggings.
RSpec.describe Tag, type: :model do
  describe '.used_in_projects' do
    let(:organisation) { create(:organisation) }
    let(:project_a) { create(:project, organisation: organisation) }
    let(:project_b) { create(:project, organisation: organisation) }

    before { ActsAsTenant.current_tenant = organisation }
    after  { ActsAsTenant.current_tenant = nil }

    def tag_on(taggable, name:)
      tag = create(:tag, name: name, organisation: organisation)
      create(:tagging, tag: tag, taggable: taggable)
      tag
    end

    it 'returns tags used by a ticket in the given projects' do
      tag = tag_on(create(:ticket, project: project_a, organisation: organisation), name: 'in-a')

      expect(Tag.used_in_projects([project_a.id])).to include(tag)
    end

    it 'excludes tags used only in other projects' do
      tag_on(create(:ticket, project: project_b, organisation: organisation), name: 'in-b')

      expect(Tag.used_in_projects([project_a.id]).pluck(:name)).not_to include('in-b')
    end

    it 'covers notes and documents, not just tickets' do
      tag_on(create(:note, project: project_a, organisation: organisation), name: 'note-a')
      tag_on(create(:document, project: project_a, organisation: organisation), name: 'doc-a')

      names = Tag.used_in_projects([project_a.id]).pluck(:name)
      expect(names).to include('note-a', 'doc-a')
    end

    it 'returns an empty relation for an empty project list (no SQL IN () error)' do
      tag_on(create(:ticket, project: project_a, organisation: organisation), name: 'x')

      expect { expect(Tag.used_in_projects([]).to_a).to eq([]) }.not_to raise_error
    end

    it 'deduplicates a tag used across multiple taggables in the same project' do
      tag = create(:tag, name: 'shared', organisation: organisation)
      create(:tagging, tag: tag, taggable: create(:ticket, project: project_a, organisation: organisation))
      create(:tagging, tag: tag, taggable: create(:note, project: project_a, organisation: organisation))

      expect(Tag.used_in_projects([project_a.id]).where(name: 'shared').count).to eq(1)
    end

    it 'accepts a relation/subquery of project ids without materialising it' do
      tag = tag_on(create(:ticket, project: project_a, organisation: organisation), name: 'rel')
      subquery = organisation.projects.where(id: project_a.id).select(:id)

      expect(Tag.used_in_projects(subquery)).to include(tag)
    end
  end
end
