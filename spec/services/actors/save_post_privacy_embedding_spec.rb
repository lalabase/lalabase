# frozen_string_literal: true

require 'rails_helper'

# What: Actors::SavePost — what happens to a comment's ATTACHMENT index when the comment's
#       privacy flips.
# Type: Actor spec, real records (the sibling save_post_spec works on doubles and cannot
#       see a database row disappear).
# Why:  The attachment of a private comment is readable by NOTHING — the content RAG
#       excludes private comments outright (Fragment::TYPE_CONTEXT_PREDICATES) and the app
#       search does not cover attachments at all. Keeping its vector around therefore buys
#       no retrieval and leaves the file's text lying in the index, which is the same
#       trade Entscheidung 5 settled for a private meeting analysis.
#
#       The ingestion gates (PostDocumentProcessingJob, Embeddings::PendingEmbeddings) stop
#       it at upload and at re-index. This spec covers the third door, the one those two
#       cannot see: a comment that was PUBLIC when its file was indexed and turns private
#       afterwards.
RSpec.describe Actors::SavePost, 'attachment index when privacy flips' do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:user)         { create(:user) }
  let(:ticket)       { create(:ticket, project: project, organisation: organisation, creator: user) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def post_with_indexed_attachment(private: false)
    post = create(:post, ticket: ticket, organisation: organisation, user: user,
                         is_private: private, visible_to_user: (private ? user : nil))
    document = create(:post_document, post: post, organisation: organisation,
                                      plain_text_version: 'Angebot ueber 4200 Euro')
    fragment = create(:fragment, fragmentable: document, organisation: organisation,
                                 plain_text_content: document.plain_text_version)
    seed_sidecar_embedding(fragment, vector: Array.new(1536, 0.1))
    [post, document, fragment]
  end

  def save(post, params)
    described_class.call(ticket: ticket, params: params, id: post.id, current_user: user)
  end

  it 'purges the attachment fragments when the comment turns private' do
    post, document, fragment = post_with_indexed_attachment

    result = save(post, { is_private: true, visible_to_user_id: user.id })

    expect(result).to be_success
    expect(Fragment.where(fragmentable_type: 'PostDocument', fragmentable_id: document.id)).to be_empty
    expect(ContentEmbedding.where(embeddable_type: 'Fragment', embeddable_id: fragment.id)).to be_empty
  end

  # The sidecar row is the half a plain `delete_all` on the fragments leaves behind, and
  # the half that actually carries the vector. Pinned separately above; pinned here as the
  # ORDER, because the subselect needs the fragment rows to still exist.
  it 'leaves the attachment itself and its extracted text alone' do
    post, document, = post_with_indexed_attachment

    save(post, { is_private: true, visible_to_user_id: user.id })

    expect(document.reload.plain_text_version).to eq('Angebot ueber 4200 Euro')
  end

  it 're-enqueues the attachment when the comment turns public again' do
    post, document, = post_with_indexed_attachment(private: true)

    expect(EmbeddingProcessingJob).to receive(:perform_later).with(
      record_class: PostDocument, record_id: document.id, fragment_association: :fragments
    )

    save(post, { is_private: false, visible_to_user_id: nil })
  end

  # No churn: an edit that does not touch privacy must not purge and must not re-enqueue,
  # or every typo fix on a private comment would cost an embedding call.
  it 'does nothing to the attachment index when privacy did not change' do
    post, document, fragment = post_with_indexed_attachment

    expect(EmbeddingProcessingJob).not_to receive(:perform_later)
      .with(hash_including(record_class: PostDocument))

    save(post, { content: 'nur der Text' })

    expect(Fragment.where(id: fragment.id)).to exist
    expect(document.reload.plain_text_version).to be_present
  end
end
