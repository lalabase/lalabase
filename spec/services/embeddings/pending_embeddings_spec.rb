# frozen_string_literal: true

require 'rails_helper'

# Embeddings::PendingEmbeddings is the ONE source of "which records are still
# waiting to be embedded", shared by EmbeddingReprocessingService (enqueue) and
# PendingBacklog (monthly discovery). The TYPE LIST comes from Embeddings::ContentTypes
# (guarded in content_types_spec.rb); what this file pins is the per-type rule as it
# reaches the two callers — the data-returning examples below would go red if a
# where-clause were dropped from an entry, which a key-level pin cannot see.
RSpec.describe Embeddings::PendingEmbeddings do
  # The relations are acts_as_tenant models, so building them needs a tenant
  # context — exactly as the callers provide (with_tenant / without_tenant).
  around { |example| ActsAsTenant.without_tenant { example.run } }

  it 'covers all nine embeddable content types' do
    expect(described_class.relations_by_model.keys).to contain_exactly(
      Note, Post, Ticket, DocumentVersion, DocumentationPage, Meeting, MeetingAnalysis,
      TicketDocument, PostDocument
    )
  end

  # An attachment without extracted text can NEVER be embedded (the service returns
  # early on a blank plain_text_version), so counting it as pending would put every
  # image and zip in the organisation into a backlog that no button can ever clear —
  # the same permanent "Verarbeitung läuft" the ai_enabled term exists to prevent
  # (Embeddings::IndexHealth). Pending means "has text and is not embedded yet".
  it 'includes an attachment with extracted text and EXCLUDES one without' do
    organisation = create(:organisation)
    ActsAsTenant.with_tenant(organisation) do
      project = create(:project, organisation: organisation)
      user = create(:user)
      ticket = create(:ticket, project: project, organisation: organisation, creator: user)
      readable = create(:ticket_document, :with_pdf, ticket: ticket, organisation: organisation,
                                                     plain_text_version: 'Angebot')
      image = create(:ticket_document, :with_png, ticket: ticket, organisation: organisation,
                                                  plain_text_version: nil)

      pending = described_class.relations_by_model[TicketDocument].to_a

      expect(pending).to include(readable)
      expect(pending).not_to include(image)
    end
  end

  # The boundary between the two above, and the one a `<> ''` term survives: the
  # extractor STORES what it read, so a PDF with empty pages leaves "\n\n" behind.
  # Ruby then says present? == false and never enqueues, so an SQL term that only
  # rules out the empty string would report this row as pending for ever.
  it 'EXCLUDES an attachment whose extracted text is only whitespace' do
    organisation = create(:organisation)
    ActsAsTenant.with_tenant(organisation) do
      project = create(:project, organisation: organisation)
      ticket = create(:ticket, project: project, organisation: organisation, creator: create(:user))
      blank = create(:ticket_document, :with_pdf, ticket: ticket, organisation: organisation,
                                                  plain_text_version: "\n\n  \t ")
      empty = create(:ticket_document, :with_pdf, ticket: ticket, organisation: organisation,
                                                  plain_text_version: '')

      pending = described_class.relations_by_model[TicketDocument].to_a

      expect(pending).not_to include(blank)
      expect(pending).not_to include(empty)
    end
  end

  it 'excludes an attachment whose embeddings were opted out' do
    organisation = create(:organisation)
    ActsAsTenant.with_tenant(organisation) do
      project = create(:project, organisation: organisation)
      post = create(:post, ticket: create(:ticket, project: project, organisation: organisation,
                                                   creator: create(:user)),
                           organisation: organisation)
      opted_out = create(:post_document, :without_embeddings, post: post, organisation: organisation,
                                                              plain_text_version: 'Angebot')

      expect(described_class.relations_by_model[PostDocument].to_a).not_to include(opted_out)
    end
  end

  # The attachment of a PRIVATE comment can be read by NOTHING: the content RAG excludes
  # private comments outright and the app search does not cover attachments at all. So
  # embedding it only ships the file's text to the provider and leaves a vector nobody can
  # reach. Same reasoning as Entscheidung 5 for a private meeting analysis.
  it 'EXCLUDES the attachment of a private comment' do
    organisation = create(:organisation)
    ActsAsTenant.with_tenant(organisation) do
      project = create(:project, organisation: organisation)
      user = create(:user)
      ticket = create(:ticket, project: project, organisation: organisation, creator: user)
      public_post = create(:post, ticket: ticket, organisation: organisation, user: user, is_private: false)
      private_post = create(:post, ticket: ticket, organisation: organisation, user: user,
                                   is_private: true, visible_to_user: user)
      visible = create(:post_document, post: public_post, organisation: organisation,
                                       plain_text_version: 'Angebot')
      hidden = create(:post_document, post: private_post, organisation: organisation,
                                      plain_text_version: 'Angebot')

      pending = described_class.relations_by_model[PostDocument].to_a

      expect(pending).to include(visible)
      expect(pending).not_to include(hidden)
    end
  end

  it 'defines "has text" the way Ruby defines present? (whitespace is not text)' do
    condition = Embeddings::ContentTypes.text_present('ticket_documents')

    expect(condition).to include("ticket_documents.plain_text_version ~ '[^[:space:]]'")
  end

  it 'defines "pending" as: embedding flag is NULL or explicitly false' do
    condition = Embeddings::ContentTypes.flag_pending('notes')
    expect(condition).to include('notes.embeddings_creation_flag IS NULL')
    expect(condition).to include('notes.embeddings_creation_flag = FALSE')
  end

  it 'returns the relations without the model keys via #relations' do
    expect(described_class.relations.size).to eq(described_class.relations_by_model.size)
    expect(described_class.relations).to all(be_a(ActiveRecord::Relation))
  end

  # Data-returning guard (review PR #247): the create_embeddings filter on the
  # Meeting relation is the ONLY thing keeping a de-indexed meeting's PII transcript
  # out of the org re-index / monthly catch-up (plan §7 "Rohtranskript ungewollt
  # auffindbar"). The key-level pins above would stay green if that where-clause
  # were dropped — this test would not.
  it 'includes an opted-in pending meeting and EXCLUDES an opted-out one (PII re-index guard)' do
    organisation = create(:organisation)
    ActsAsTenant.with_tenant(organisation) do
      project = create(:project, organisation: organisation)
      user = create(:user)
      opted_in  = create(:meeting, project: project, organisation: organisation, creator: user,
                                   create_embeddings: true, notes: 'pending content')
      opted_out = create(:meeting, project: project, organisation: organisation, creator: user,
                                   create_embeddings: false, notes: 'pending content')

      relation = described_class.relations_by_model[Meeting]
      expect(relation).to include(opted_in)
      expect(relation).not_to include(opted_out)
    end
  end

  # Data-returning guard (Gespräche Slice 7b, #247 lesson: key-level pins alone would
  # stay green if the where-clause were dropped). A MeetingAnalysis is embeddable ONLY
  # when it is BOTH published (is_private = false) AND search-released
  # (include_in_search = true) — the fail-closed rule keeping a private analysis's PII
  # out of the org re-index / monthly catch-up (plan §5, Entscheidung 5).
  it 'includes a published+search-released pending analysis and EXCLUDES private / not-released ones' do
    organisation = create(:organisation)
    ActsAsTenant.with_tenant(organisation) do
      project = create(:project, organisation: organisation)
      meeting = create(:meeting, project: project, organisation: organisation)
      indexed = create(:meeting_analysis, meeting: meeting, organisation: organisation,
                                          is_private: false, include_in_search: true, content: 'body')
      private_one = create(:meeting_analysis, meeting: meeting, organisation: organisation,
                                              is_private: true, include_in_search: true, content: 'body')
      not_released = create(:meeting_analysis, meeting: meeting, organisation: organisation,
                                               is_private: false, include_in_search: false, content: 'body')

      relation = described_class.relations_by_model[MeetingAnalysis]
      expect(relation).to include(indexed)
      expect(relation).not_to include(private_one)
      expect(relation).not_to include(not_released)
    end
  end

  # Every relation must survive the exact PendingBacklog aggregation (group by org +
  # min(created_at)). The DocumentVersion relation JOINs documents — both tables have
  # organisation_id AND created_at — so an unqualified group/minimum would raise
  # "column ... is ambiguous" and crash the monthly resume. Runs the real SQL.
  it 'groups every relation by organisation without SQL ambiguity (monthly-resume path)' do
    described_class.relations.each do |relation|
      expect { relation.group(:organisation_id).minimum(:created_at) }.not_to raise_error
    end
  end
end
