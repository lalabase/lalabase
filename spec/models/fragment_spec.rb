# frozen_string_literal: true

# == Schema Information
#
# Table name: fragments
#
#  id                 :uuid             not null, primary key
#  fragmentable_type  :string           not null
#  plain_text_content :text
#  version_token      :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  fragmentable_id    :uuid             not null
#  organisation_id    :uuid             not null
#
# Indexes
#
#  index_fragments_on_fragmentable     (fragmentable_type,fragmentable_id)
#  index_fragments_on_organisation_id  (organisation_id)
#  index_fragments_on_version_token    (version_token)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
require 'rails_helper'

# Isolated spec for Fragment.for_project_context — the HARD boundary of content-RAG
# (Plan §4.1): exactly ONE project + private posts excluded. DELIBERATELY tested
# WITHOUT nearest_neighbors/embedding, so that each of the four polymorphic
# project_id paths (JOIN disjuncts) is pinned individually and noise-free — a mutation
# on a single disjunct (e.g. note branch removed) breaks here precisely.
RSpec.describe Fragment, '.for_project_context' do
  let(:organisation)  { create(:organisation) }
  let(:project)       { create(:project, organisation: organisation) }
  let(:other_project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def fragment_for(fragmentable)
    create(:fragment, fragmentable: fragmentable, organisation: fragmentable.organisation)
  end

  def scoped_fragmentable_ids
    Fragment.for_project_context(project).map(&:fragmentable_id)
  end

  def document_version_in(target_project)
    doc = create(:document, project: target_project, organisation: organisation)
    create(:document_version, document: doc, organisation: organisation)
  end

  describe 'includes each fragmentable type bound to the project (one disjunct per type)' do
    it 'includes a Ticket of the project' do
      ticket = create(:ticket, project: project, organisation: organisation)
      fragment_for(ticket)
      expect(scoped_fragmentable_ids).to include(ticket.id)
    end

    it 'includes a Note of the project' do
      note = create(:note, project: project, organisation: organisation)
      fragment_for(note)
      expect(scoped_fragmentable_ids).to include(note.id)
    end

    it 'includes a public Post on a ticket of the project' do
      ticket = create(:ticket, project: project, organisation: organisation)
      post = create(:post, ticket: ticket, organisation: organisation, is_private: false)
      fragment_for(post)
      expect(scoped_fragmentable_ids).to include(post.id)
    end

    it 'includes a DocumentVersion whose document is in the project' do
      dv = document_version_in(project)
      fragment_for(dv)
      expect(scoped_fragmentable_ids).to include(dv.id)
    end
  end

  describe 'excludes the same type when bound to ANOTHER project (cross-project, per type)' do
    it 'excludes a Ticket of another project' do
      ticket = create(:ticket, project: other_project, organisation: organisation)
      fragment_for(ticket)
      expect(scoped_fragmentable_ids).not_to include(ticket.id)
    end

    it 'excludes a Note of another project' do
      note = create(:note, project: other_project, organisation: organisation)
      fragment_for(note)
      expect(scoped_fragmentable_ids).not_to include(note.id)
    end

    it 'excludes a Post on a ticket of another project' do
      ticket = create(:ticket, project: other_project, organisation: organisation)
      post = create(:post, ticket: ticket, organisation: organisation, is_private: false)
      fragment_for(post)
      expect(scoped_fragmentable_ids).not_to include(post.id)
    end

    it 'excludes a DocumentVersion whose document is in another project' do
      dv = document_version_in(other_project)
      fragment_for(dv)
      expect(scoped_fragmentable_ids).not_to include(dv.id)
    end
  end

  describe 'private posts are excluded even within the project' do
    it 'excludes a private Post of the project' do
      ticket = create(:ticket, project: project, organisation: organisation)
      private_post = create(:post, ticket: ticket, organisation: organisation,
                                   is_private: true, visible_to_user_id: nil)
      fragment_for(private_post)
      expect(scoped_fragmentable_ids).not_to include(private_post.id)
    end
  end
end

# S3a T3: the org-wide form of the same boundary (a per-TYPE project map). Its
# own three guards (empty map, unknown type, empty id list) are what keep a
# broken map from degrading into "every fragment of the organisation" — pinned
# here, noise-free like the single-project scope above.
RSpec.describe Fragment, '.for_context_map' do
  let(:organisation)  { create(:organisation) }
  let(:project)       { create(:project, organisation: organisation) }
  let(:other_project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let!(:ticket_here)  { create(:ticket, project: project, organisation: organisation) }
  let!(:ticket_there) { create(:ticket, project: other_project, organisation: organisation) }
  let!(:note_here)    { create(:note, project: project, organisation: organisation, creator: create(:user)) }

  before do
    [ticket_here, ticket_there, note_here].each do |fragmentable|
      create(:fragment, fragmentable: fragmentable, organisation: organisation)
    end
  end

  def ids_for(map)
    Fragment.for_context_map(map).map(&:fragmentable_id)
  end

  it 'binds a DIFFERENT project set per type' do
    ids = ids_for('Ticket' => [other_project.id], 'Note' => [project.id])

    expect(ids).to contain_exactly(ticket_there.id, note_here.id)
  end

  it 'yields nothing for an empty map (fail-closed)' do
    expect(ids_for({})).to eq([])
  end

  it 'yields nothing for an unknown type' do
    expect(ids_for('Widget' => [project.id])).to eq([])
  end

  it 'yields nothing for a type with an empty id list' do
    expect(ids_for('Ticket' => [])).to eq([])
  end

  it 'equals for_project_context when every type is bound to the one project (one owner, two call shapes)' do
    map = Fragment::TYPE_CONTEXT_PREDICATES.keys.index_with { [project.id] }

    expect(ids_for(map)).to match_array(Fragment.for_project_context(project).map(&:fragmentable_id))
  end
end
