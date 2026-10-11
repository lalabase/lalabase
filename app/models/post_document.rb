# frozen_string_literal: true

# == Schema Information
#
# Table name: post_documents
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
#  post_id                  :uuid             not null
#
# Indexes
#
#  index_post_documents_on_organisation_id  (organisation_id)
#

class PostDocument < ApplicationRecord
  acts_as_tenant(:organisation)
  has_one_attached :post_document_file
  belongs_to :post, touch: true

  has_many :fragments, as: :fragmentable, dependent: :destroy

  # Twin of TicketDocument#filename — see there for why it lives on the model.
  def filename
    post_document_file&.filename.to_s
  end

  validates :post_document_file, presence: true
end
