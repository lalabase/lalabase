# frozen_string_literal: true

# How the Indexierung page draws one embeddable content type: label and icon per
# Embeddings::ContentTypes key. The TYPE LIST is not here — the view iterates the
# registry and asks this helper how to draw an entry, so a tenth type shows up on the
# page the day it is registered. A key without a row here is a red guard
# (spec/helpers/ai_sync_status_helper_spec.rb), never a silently blank card.
module AiSyncStatusHelper
  # An icon only. Until 2026-11-12 each type also had a colour (card, heading, bar), and
  # nine colours on one page named nothing a reader could tell apart; the rows of the
  # type table now stand in the page's own tones.
  TYPE_PRESENTATION = {
    notes: { icon: 'journal-text' },
    posts: { icon: 'chat-left-text' },
    tickets: { icon: 'ticket-perforated' },
    document_versions: { icon: 'file-earmark-text' },
    documentation_pages: { icon: 'book' },
    meetings: { icon: 'mic' },
    meeting_analyses: { icon: 'clipboard-data' },
    ticket_documents: { icon: 'paperclip' },
    post_documents: { icon: 'paperclip' }
  }.freeze

  def ai_sync_type_label(key)
    t("views.organisations.ai_sync_statuses.show.types.#{key}")
  end

  # @raise [KeyError] for a key without a row — a blank card would hide exactly the gap
  #   this page exists to show.
  def ai_sync_type_presentation(key)
    TYPE_PRESENTATION.fetch(key)
  end
end
