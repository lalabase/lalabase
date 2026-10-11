# frozen_string_literal: true

# The data attributes every Lexxy editor in the app carries for the image rule
# (spike plan Inline-Bilder, D5; Paket 2). ONE place builds them, the eight forms call it.
#
#   <%= form.lexxy_rich_text_area :content, **lexxy_embed_editor_options(attachment_field: "post[post_document_files][]") %>
#
# `attachment_field` is the `name` of the file input in the same form that refused files
# are redirected to (nil when the form has none, e.g. notes). The controller looks it up
# through the enclosing form, so the editor does not need to wrap the input.
module RichTextEmbedsHelper
  def lexxy_embed_editor_options(attachment_field: nil, **options)
    data = {
      controller: 'neo-rich-text-embeds',
      action: 'lexxy:file-accept->neo-rich-text-embeds#accept',
      neo_rich_text_embeds_max_bytes_value: RichTextEmbeds::MAX_BYTE_SIZE,
      neo_rich_text_embeds_max_megabytes_value: RichTextEmbeds.max_megabytes,
      neo_rich_text_embeds_image_types_value: RichTextEmbeds.permitted_attachment_types,
      neo_rich_text_embeds_attachment_selector_value: attachment_field && %(input[type="file"][name="#{attachment_field}"]),
      hint_not_image: t('views.action_text.embed_hint_not_image'),
      hint_too_large: t('views.action_text.embed_hint_too_large'),
      hint_redirected: attachment_field && t('views.action_text.embed_hint_redirected'),
      # Only where the file has nowhere to go (notes): the one thing the user can still
      # do about a merely oversized image.
      hint_shrink: attachment_field ? nil : t('views.action_text.embed_hint_shrink')
    }.compact

    options.merge(data: data.merge(options.fetch(:data, {})))
  end
end
