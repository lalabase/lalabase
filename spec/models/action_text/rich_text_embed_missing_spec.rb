# frozen_string_literal: true

require 'rails_helper'

# What:  What a rich text does when the image behind an embed is gone: the sgid no longer
#        resolves (attachment and blob purged), or the blob row survived but its file
#        did not (aborted upload, file-level deletion).
# Type:  Model spec (spike S4 / decisions E3, E5, D3; green since Paket 1, 2026-08-23).
# Why:   E3: Rails renders a dead sgid through MissingAttachable, never a broken <img>; the
#        stored HTML is not rewritten. Blobs get their own partial with a neutral i18n text
#        (config/initializers/active_storage_missing_attachable_partial.rb); the generic
#        partial stays Rails', so a deleted wiki-mention target keeps its glyph (D3).
#        E5, third state: a blob row without a file resolves fine, and before Paket 1 saving
#        a text that referenced it raised ActiveStorage::FileNotFoundError inside
#        before_save (identify downloads the first chunk): a 500 and a lost draft.
#        RichTextEmbedGuard now refuses it with a message.
RSpec.describe 'Rich text embed without its image', :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    ActiveStorage::Current.url_options = { host: 'www.example.com' }
  end
  after { ActsAsTenant.current_tenant = nil }

  def png_blob
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("\x89PNG\r\n\x1a\n#{'x' * 64}"), filename: 'shot.png', content_type: 'image/png'
    )
  end

  def embed_html(blob) = %(<div>Schritt 1</div><action-text-attachment sgid="#{blob.attachable_sgid}"></action-text-attachment>)

  describe 'E3: attachment and blob purged (sgid does not resolve)' do
    let(:blob) { png_blob }
    let!(:ticket) { create(:ticket, project: project, organisation: organisation, content: embed_html(blob)) }

    before do
      ticket.content.embeds.each(&:destroy!)
      blob.purge
      ticket.reload
    end

    it 'keeps the attachment node in the stored HTML (nothing is rewritten)' do
      expect(ticket.content.body.to_html).to include('<action-text-attachment')
    end

    it 'renders the i18n placeholder and no <img> with a dead link' do
      html = ticket.content.to_s

      expect(html).not_to include('<img')
      expect(html).to include(I18n.t('views.action_text.missing_image'))
      expect(html).not_to include('☒')
    end

    it 'keeps the placeholder text out of the plain text used by search and mails' do
      expect(ticket.plain_text_version).not_to include(I18n.t('views.action_text.missing_image'))
    end

    # A deleted wiki-mention target is the same mechanism (a sgid) and must NOT read as a
    # missing image: the blob partial hangs on ActiveStorage::Blob, not on the default.
    it 'leaves a deleted mention target with the generic glyph, not the image text' do
      other = create(:note, project: project, organisation: organisation, title: 'Zielnotiz')
      mention_sgid = other.attachable_sgid
      note = create(:note, project: project, organisation: organisation,
                           content: %(<div>Siehe</div><action-text-attachment sgid="#{mention_sgid}" content-type="application/vnd.actiontext.mention"></action-text-attachment>))
      other.destroy!

      html = note.reload.content.to_s
      expect(html).not_to include(I18n.t('views.action_text.missing_image'))
      expect(html).to include('☒')
    end

    it 'still renders the text around the gap' do
      expect(ticket.content.to_s).to include('Schritt 1')
    end
  end

  describe 'E5, third state: blob row present, file gone' do
    # A direct upload mints the row first (identified: nil, no file) and sends the bytes
    # with a second request. When that PUT never arrives, this is what remains. A blob
    # from create_and_upload! would NOT show the problem: it is already identified and
    # the before_save short-circuits (identifiable.rb), so the missing file goes unnoticed.
    let(:blob) do
      ActiveStorage::Blob.create_before_direct_upload!(
        filename: 'shot.png', byte_size: 72, checksum: 'XUFAKrxLKna5cZ2REBfFkg==', content_type: 'image/png'
      )
    end

    it 'is exactly the state an aborted upload leaves behind' do
      expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)
      expect(blob.service.exist?(blob.key)).to be(false)
      expect(blob.identified).to be_falsey
    end

    it 'refuses the text with a content error instead of the former FileNotFoundError 500' do
      ticket = build(:ticket, project: project, organisation: organisation, content: embed_html(blob))

      expect { ticket.save }.not_to raise_error
      expect(ticket.save).to be(false)
      expect(ticket.errors.added?(:content, :embed_file_missing, filename: 'shot.png')).to be(true)
    end

    # Since Rails 8.1 the rich text identifies its new embeds in its own before_validation
    # (before_save until 8.0), so the trap sits in the validation the guard runs ahead of.
    it 'would still be a 500 without the guard (the trap is real, not theoretical)' do
      ticket = build(:ticket, project: project, organisation: organisation, content: embed_html(blob))

      expect { ticket.content.validate }.to raise_error(ActiveStorage::FileNotFoundError)
    end
  end
end
