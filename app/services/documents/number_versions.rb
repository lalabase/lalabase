# frozen_string_literal: true

# The stock's version numbers (doc/dokumentansicht_plan.md, S1): every document
# with an unnumbered version gets ALL its versions numbered again,
# chronologically from 1 (ROW_NUMBER over created_at, id). All of them, not just the unnumbered: a version
# created between the deploy and this run carries a 1 that the actor gave it
# against no numbered sibling, and only a fresh count keeps the order true.
# Numbers were never shown before this run, so renumbering costs nothing.
# Idempotent: a fully numbered document is left alone.
# Entry point: Documents::NumberVersions.call(organisation:)
module Documents
  class NumberVersions
    Result = Struct.new(:documents, :versions, keyword_init: true)

    def self.call(organisation:)
      new(organisation: organisation).call
    end

    def initialize(organisation:)
      @organisation = organisation
    end

    def call
      documents = 0
      versions = 0

      ActsAsTenant.with_tenant(@organisation) do
        # ONE query for the documents that need a count, not one per document.
        unnumbered = DocumentVersion.where(organisation_id: @organisation.id, number: nil).select(:document_id)
        Document.where(organisation_id: @organisation.id, id: unnumbered).find_each do |document|
          versions += renumber(document)
          documents += 1
        end
      end

      Result.new(documents: documents, versions: versions)
    end

    private

    # Two statements per document, in one transaction, no callbacks and no
    # broadcast of every row into open pages. Cleared first: the unique index on
    # (document_id, number) is checked row by row, so a single UPDATE that swaps
    # numbers between two versions of one document would refuse mid-way.
    #
    # Under the document's row lock, the one Actors::SaveDocumentVersion takes
    # (review of #779): the clear locks the rows that exist, not the one an
    # upload inserts into the window before the count. That row would carry a 1
    # against no numbered sibling, the count would hand the same 1 to the oldest
    # stock row, and the unique index would abort the run. An upload now waits
    # for this commit and counts from the new maximum.
    def renumber(document)
      quoted_id = DocumentVersion.connection.quote(document.id)
      DocumentVersion.transaction do
        document.lock!
        document.document_versions.update_all(number: nil)
        # Raw, not update_all(string): the relation would append its own WHERE
        # behind the statement's, which is not SQL.
        DocumentVersion.connection.exec_update(<<~SQL.squish, 'DocumentVersion renumber')
          UPDATE document_versions SET number = numbered.rn
          FROM (
            SELECT id, ROW_NUMBER() OVER (ORDER BY created_at, id) AS rn
            FROM document_versions WHERE document_id = #{quoted_id}
          ) AS numbered
          WHERE document_versions.id = numbered.id
        SQL
      end
    end
  end
end
