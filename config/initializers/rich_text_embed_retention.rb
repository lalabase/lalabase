# frozen_string_literal: true

# Keeps the images of a rich text whose attachment nodes no longer resolve (a sgid signed
# with a previous secret_key_base). Why and how: app/models/concerns/rich_text_embed_retention.rb.
ActiveSupport.on_load(:action_text_rich_text) do
  include RichTextEmbedRetention
end
