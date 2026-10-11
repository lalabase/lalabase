# frozen_string_literal: true

# How the Indexierung page draws one embeddable content type: label, icon and colour per
# Embeddings::ContentTypes key. The TYPE LIST is not here — the view iterates the
# registry and asks this helper how to draw an entry, so a tenth type shows up on the
# page the day it is registered. A key without a row here is a red guard
# (spec/helpers/ai_sync_status_helper_spec.rb), never a silently blank card.
module AiSyncStatusHelper
  # Full class strings, never assembled from a colour name: Tailwind only emits the
  # classes it finds spelled out in a scanned file, and app/helpers is scanned.
  TYPE_PRESENTATION = {
    notes: { icon: 'journal-text', card: 'bg-purple-50 border-purple-200',
             heading: 'text-purple-800', bar: 'bg-purple-500' },
    posts: { icon: 'chat-left-text', card: 'bg-cobalt-50 border-cobalt-200',
             heading: 'text-cobalt-800', bar: 'bg-cobalt-500' },
    tickets: { icon: 'ticket-perforated', card: 'bg-green-50 border-green-200',
               heading: 'text-green-800', bar: 'bg-green-500' },
    document_versions: { icon: 'file-earmark-text', card: 'bg-orange-50 border-orange-200',
                         heading: 'text-orange-800', bar: 'bg-orange-500' },
    documentation_pages: { icon: 'book', card: 'bg-teal-50 border-teal-200',
                           heading: 'text-teal-800', bar: 'bg-teal-500' },
    meetings: { icon: 'mic', card: 'bg-pink-50 border-pink-200',
                heading: 'text-pink-800', bar: 'bg-pink-500' },
    meeting_analyses: { icon: 'clipboard-data', card: 'bg-rose-50 border-rose-200',
                        heading: 'text-rose-800', bar: 'bg-rose-500' },
    ticket_documents: { icon: 'paperclip', card: 'bg-amber-50 border-amber-200',
                        heading: 'text-amber-800', bar: 'bg-amber-500' },
    post_documents: { icon: 'paperclip', card: 'bg-lime-50 border-lime-200',
                      heading: 'text-lime-800', bar: 'bg-lime-500' }
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
