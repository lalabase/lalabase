# frozen_string_literal: true

# Safety net on ActionText::RichText (included by config/initializers/rich_text_embed_retention.rb):
# a stored embed stays attached while the body still holds an attachment node whose sgid
# does not resolve.
#
# Rails rebuilds `embeds` in its own before_validation from the sgids that resolve
# (rich_text.rb: `self.embeds = body.attachables.grep(ActiveStorage::Blob).uniq`). A sgid
# stops resolving for everything stored before a secret_key_base rotation, and then
# editing only the words of a text detached every image and enqueued the purge of its
# file. Which embed a dead node meant cannot be told without
# the old key, so every stored embed that would be dropped is kept. The price is that an
# image removed in the same edit stays attached until the text is saved again with
# readable nodes; RichTextSgidResign makes them readable.
#
# Runs after Rails' callback because this module is included after the class body.
module RichTextEmbedRetention
  extend ActiveSupport::Concern

  included do
    before_validation :retain_embeds_behind_unresolved_nodes, if: -> { persisted? && body.present? }
  end

  private

  def retain_embeds_behind_unresolved_nodes
    attachables = body.attachables
    return unless attachables.any?(ActionText::Attachables::MissingAttachable)

    resolved = attachables.grep(ActiveStorage::Blob)
    stored = ActiveStorage::Blob.joins(:attachments)
                                .where(active_storage_attachments: { record_type: self.class.name, record_id: id, name: 'embeds' })
                                .to_a
    retained = stored.reject { |blob| resolved.include?(blob) }
    return if retained.empty?

    self.embeds = (resolved + retained).uniq
  end
end
