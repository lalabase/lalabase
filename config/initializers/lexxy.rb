# frozen_string_literal: true

# Lexxy ships as a GLOBAL Action Text editor: on Rails 8.0.x (no editor-adapter API yet)
# it aliases rich_text_area -> Lexxy for EVERY model. Lexxy IS the only editor of the app
# since Paket 2 of the inline images (doc/inline_bilder_paket_2_plan.md, Trix is gone),
# but the alias stays OFF on purpose: every form calls form.lexxy_rich_text_area with
# lexxy_embed_editor_options (RichTextEmbedsHelper) explicitly, so the image rule is
# visible at the call site and a bare rich_text_area cannot slip in without it
# (guard: spec/views/no_trix_guard_spec.rb).
#
# Read by Lexxy::Engine's to_prepare hook, which runs after this initializer.
Rails.application.config.lexxy.override_action_text_defaults = false
