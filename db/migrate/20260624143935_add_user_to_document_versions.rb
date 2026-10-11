# frozen_string_literal: true

# Records who uploaded a document version. Nullable on purpose: historic
# versions predate this column and have no reliable uploader — they stay NULL
# and surface as "Unknown" in the UI rather than being guessed via a backfill.
class AddUserToDocumentVersions < ActiveRecord::Migration[8.0]
  def change
    add_reference :document_versions, :user, type: :uuid, null: true, foreign_key: true, index: true
  end
end
