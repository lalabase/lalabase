# frozen_string_literal: true

# One PENDING, opted-in record per Embeddings::ContentTypes key, for guards that walk the
# whole registry (parity, cross-organisation isolation). Test scaffolding, not a fourth
# list: the parity spec pins it against the registry's keys, so a tenth type fails there
# until it has a builder here.
#
# Parents that are themselves embeddable (the ticket under a comment or an attachment,
# the comment under an attachment, the meeting under an analysis) are created already
# PROCESSED or opted out, so the one pending record an example sees is the one the key
# names, not its parent.
module EmbeddableContentTypesHelpers
  def create_pending_record(key, organisation:, project:, user:)
    ActsAsTenant.with_tenant(organisation) do
      case key
      when :notes
        create(:note, project: project, organisation: organisation, creator: user, create_embeddings: true)
      when :posts
        create(:post, ticket: processed_ticket(organisation, project, user), organisation: organisation,
                      user: user, create_embeddings: true)
      when :tickets
        create(:ticket, project: project, organisation: organisation, creator: user)
      when :document_versions
        document = create(:document, project: project, organisation: organisation)
        version = create(:document_version, document: document, organisation: organisation, create_embeddings: true)
        document.update!(current_version: version)
        version
      when :documentation_pages
        create(:documentation_page, documentation_set: create(:documentation_set, project: project))
      when :meetings
        create(:meeting, project: project, organisation: organisation, creator: user, create_embeddings: true)
      when :meeting_analyses
        meeting = create(:meeting, project: project, organisation: organisation, creator: user, create_embeddings: false)
        create(:meeting_analysis, meeting: meeting, organisation: organisation, is_private: false, include_in_search: true)
      when :ticket_documents
        create(:ticket_document, ticket: processed_ticket(organisation, project, user), organisation: organisation,
                                 plain_text_version: 'Angebot')
      when :post_documents
        post = create(:post, ticket: processed_ticket(organisation, project, user), organisation: organisation,
                             user: user, create_embeddings: false)
        create(:post_document, post: post, organisation: organisation, plain_text_version: 'Angebot')
      else
        raise ArgumentError, "no pending-record builder for #{key.inspect}: a registered type must be probed"
      end
    end
  end

  private

  def processed_ticket(organisation, project, user)
    create(:ticket, project: project, organisation: organisation, creator: user, embeddings_creation_flag: true)
  end
end

RSpec.configure do |config|
  config.include EmbeddableContentTypesHelpers
end
