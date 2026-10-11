# frozen_string_literal: true

# == Schema Information
#
# Table name: ticket_documents
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
#  ticket_id                :uuid             not null
#
# Indexes
#
#  index_ticket_documents_on_organisation_id           (organisation_id)
#  index_ticket_documents_on_ticket_id_and_created_at  (ticket_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (ticket_id => tickets.id)
#
FactoryBot.define do
  factory :ticket_document do
    association :ticket
    association :organisation

    after(:build) do |ticket_document|
      ticket_document.ticket_document_file.attach(
        io: StringIO.new('test file content'),
        filename: 'test_document.txt',
        content_type: 'text/plain'
      )
    end

    # The disposition decision keys purely on blob.content_type, so every disposition
    # trait pins it with identify: false — otherwise ActiveStorage's Marcel sniffing
    # of the fake bytes would decide the type and make the assertion non-deterministic.

    # Inline-allowed type (ActiveStorage.content_types_allowed_inline) — should
    # open in the browser, not force a download.
    trait :with_pdf do
      after(:build) do |ticket_document|
        ticket_document.ticket_document_file.attach(
          io: StringIO.new('%PDF-1.4 fake pdf content'),
          filename: 'test_document.pdf',
          content_type: 'application/pdf',
          identify: false
        )
      end
    end

    # Second inline-allowed type (an image, not a PDF). Together with :with_svg this
    # proves the decision is the content-type allowlist, NOT a naive "is it an image".
    trait :with_png do
      after(:build) do |ticket_document|
        ticket_document.ticket_document_file.attach(
          io: StringIO.new('\x89PNG\r\n fake png bytes'),
          filename: 'diagram.png',
          content_type: 'image/png',
          identify: false
        )
      end
    end

    # Script-capable type (ActiveStorage.content_types_to_serve_as_binary) — must
    # ALWAYS be forced to download, never rendered inline from our origin (stored XSS).
    trait :with_html do
      after(:build) do |ticket_document|
        ticket_document.ticket_document_file.attach(
          io: StringIO.new('<script>alert(document.cookie)</script>'),
          filename: 'evil.html',
          content_type: 'text/html',
          identify: false
        )
      end
    end

    # An IMAGE that is nonetheless script-capable (SVG can embed <script>). Rails forces
    # it to download (serve_as_binary). This is the sneaky case a naive "inline images"
    # implementation would get wrong — the test must keep it a download.
    trait :with_svg do
      after(:build) do |ticket_document|
        ticket_document.ticket_document_file.attach(
          io: StringIO.new('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'),
          filename: 'evil.svg',
          content_type: 'image/svg+xml',
          identify: false
        )
      end
    end
  end
end
