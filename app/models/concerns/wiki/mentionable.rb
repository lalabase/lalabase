# frozen_string_literal: true

module Wiki
  # Makes a model linkable from a wiki note via an @-mention. Shared by Note and Document
  # so "what a mentionable is" lives in one place (DRY).
  #
  # ActionText::Attachable gives the model:
  #   - attachable_sgid — the signed id minted into the <action-text-attachment> when the
  #     mention picker inserts it (resolved back via Wiki::MentionResolver / from_attachable_sgid),
  #   - to_attachable_partial_path — which partial renders a stored mention when the note is shown.
  #
  # The partial path is derived from the model name (notes → organisations/notes/mention,
  # documents → organisations/documents/mention), so each type renders its own chip without
  # this concern knowing the concrete classes.
  module Mentionable
    extend ActiveSupport::Concern

    # PREPENDED so these win the ancestor race against ActionText::Attachable's defaults
    # (e.g. its to_attachable_partial_path) regardless of include order. Defining them
    # directly on this concern lost that race, because the included-hook below pulls
    # Attachable in and it landed above them — verified. Prepend sidesteps the ordering.
    module Overrides
      def to_attachable_partial_path
        "organisations/#{self.class.model_name.plural}/mention"
      end

      # Plain-text projection (used by Note#plain_text_version and search indexing): the
      # title, not an empty attachment, so a mention still contributes searchable text.
      def attachable_plain_text_representation(_caption = nil)
        title.to_s
      end

      # Marks ActionText attachments of this record as mentions, so Wiki::Mention.nodes
      # detects them and the serializer turns them into lalabase: links (one source of truth
      # for the suffix via Wiki::Mention).
      def attachable_content_type
        "application/vnd.actiontext.#{Wiki::Mention::CONTENT_TYPE_SUFFIX}"
      end
    end

    included do
      include ActionText::Attachable
      prepend Overrides
    end
  end
end
