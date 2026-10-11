# frozen_string_literal: true

# A rich text whose image was purged keeps its <action-text-attachment sgid> node; Rails
# resolves the dead sgid to ActionText::Attachables::MissingAttachable and renders it
# through `model.to_missing_attachable_partial_path` (missing_attachable.rb). The default
# partial is a "☒" glyph. This patch gives BLOBS their own partial with a neutral text
# (spike plan Inline-Bilder, E3 / D3). Deliberately not the generic
# action_text/attachables/_missing_attachable partial: wiki mentions are the same
# mechanism (a sgid on a Ticket or Note), and a deleted mention target must not read as
# a missing image. Same to_prepare pattern as the tenant patch next door.
Rails.application.config.to_prepare do
  ActiveStorage::Blob.singleton_class.prepend(Module.new do
    def to_missing_attachable_partial_path
      'active_storage/blobs/missing'
    end
  end)
end
