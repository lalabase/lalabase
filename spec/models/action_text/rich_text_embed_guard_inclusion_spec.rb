# frozen_string_literal: true

require 'rails_helper'

# What:  Every model that declares `has_rich_text` includes RichTextEmbedGuard, and the
#        numbers that rule images in rich texts have exactly ONE owner.
# Type:  Static guard (spike plan Inline-Bilder, D2 and D5, 2026-08-23).
# Why:   D2 put the validator on the carriers (a concern) instead of on
#        ActionText::RichText, because autosave reports RichText errors under
#        `rich_text_content.body`, never under :content. The price of that choice is that a
#        fourth `has_rich_text` model could silently skip the rule; this spec makes it red.
#        D5: the type list, the size limit and the variant dimensions are read by the
#        validator, the editor attributes, the JS handler and the messages; a second
#        literal in app/ is a drift between browser, server and text.
RSpec.describe 'RichTextEmbedGuard inclusion and single ownership' do
  let(:model_files) { Dir[Rails.root.join('app/models/**/*.rb')] }

  it 'is included by every model with has_rich_text' do
    offenders = model_files.filter_map do |file|
      source = File.read(file)
      next unless source.match?(/^\s*has_rich_text\b/)
      next if source.match?(/^\s*include RichTextEmbedGuard\b/)

      file.delete_prefix(Rails.root.to_s)
    end

    expect(offenders).to be_empty
  end

  it 'guards the three carriers at runtime' do
    expect([Ticket, Post, Note].map { |m| m.include?(RichTextEmbedGuard) }).to all(be(true))
  end

  # Scoped to the files that deal with rich texts, editors and embeds: other rules may
  # legitimately share the number (EmailLog::MAX_DECOMPRESSED_SIZE is also 10 MB and has
  # nothing to do with images).
  it 'keeps the size limit and the image type list out of the embed code except for RichTextEmbeds' do
    owner = Rails.root.join('app/models/rich_text_embeds.rb').to_s
    # UserAvatar owns the PROFILE-picture rules (its own type list and limit,
    # avatar S2) and names this module as its pattern precedent — a second
    # legitimate single-owner, not a scattered literal.
    avatar_owner = Rails.root.join('app/models/user_avatar.rb').to_s
    offenders = Dir[Rails.root.join('app/**/*.{rb,erb,js}')].filter_map do |file|
      next if [owner, avatar_owner].include?(file)

      source = File.read(file)
      next unless source.match?(/embed|rich_text|lexxy|action_text|trix/i)
      next unless source.match?(%r{10\.megabytes|image/webp|image/png["',]\s*["']image/})

      file.delete_prefix(Rails.root.to_s)
    end

    expect(offenders).to be_empty
  end

  it 'keeps the variant dimensions out of the views (the partial reads the constants)' do
    offenders = Dir[Rails.root.join('app/views/**/*.erb')].filter_map do |file|
      next unless File.read(file).match?(/\[\s*1024\s*,\s*768\s*\]|\[\s*800\s*,\s*600\s*\]/)

      file.delete_prefix(Rails.root.to_s)
    end

    expect(offenders).to be_empty
  end

  it 'translates every embed error and hint in German and English' do
    keys = %w[embed_not_an_image embed_too_large embed_file_missing embed_foreign_organisation embed_missing]
    %i[de en].each do |locale|
      translations = I18n.backend.send(:translations)[locale]
      keys.each do |key|
        expect(translations.dig(:activerecord, :errors, :messages, key.to_sym)).to be_present, "#{locale}: activerecord.errors.messages.#{key}"
      end
      %i[missing_image embed_hint_not_image embed_hint_too_large].each do |key|
        expect(translations.dig(:views, :action_text, key)).to be_present, "#{locale}: views.action_text.#{key}"
      end
    end
  end
end
