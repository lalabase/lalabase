# frozen_string_literal: true

# == Schema Information
#
# Table name: ticket_documents
#
#  id                       :uuid             not null, primary key
#  create_embeddings        :boolean          default(TRUE)
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  plain_text_version       :text
#  plain_text_word_count    :integer
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  organisation_id          :uuid             not null
#  ticket_id                :uuid             not null
#
# Indexes
#
#  index_ticket_documents_on_organisation_id           (organisation_id)
#  index_ticket_documents_on_ticket_id_and_created_at  (ticket_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (ticket_id => tickets.id)
#
class TicketDocument < ApplicationRecord
  acts_as_tenant(:organisation)
  has_one_attached :ticket_document_file
  belongs_to :ticket, touch: true

  has_many :fragments, as: :fragmentable, dependent: :destroy

  validates :ticket_document_file, presence: true

  # The file's name, asked by everything that has to NAME this document (the RAG
  # prompt label). Here rather than at the call sites so no consumer reaches through
  # the attachment and quietly loses the preload with it.
  def filename
    ticket_document_file&.filename.to_s
  end
end
