# frozen_string_literal: true

require 'rails_helper'

# What:  The contract of RichTextEmbedGuard on every carrier of a rich text (Ticket,
#        Post, Note): only images, at most RichTextEmbeds::MAX_BYTE_SIZE, only blobs of
#        the own organisation, only files that exist, judged on the DELTA of a save.
# Type:  Model spec (spike S2, green since Paket 1, 2026-08-23).
# Why:   Three traps, each pinned by an example that was red before: `embeds` is EMPTY at
#        validation time (the guard reads body.attachables); `content_type` is the
#        client's declaration until the blob is identified (the guard identifies); and a
#        validator over the WHOLE text would lock the four production tickets that carry a
#        PDF tile from before the Trix blocker (the guard validates new blobs only, D10).
#        Fixture note: create_and_upload!(identify: false) still marks the blob identified
#        (Blob#unfurl), so the "PDF declared as PNG" case is built like a real direct
#        upload: create_before_direct_upload! plus service.upload (identified: nil).
RSpec.describe 'Rich text embed validation', :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:png_header) { "\x89PNG\r\n\x1a\n".b }
  let(:pdf_header) { '%PDF-1.4 '.b }

  def uploaded(bytes, filename:, content_type:)
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: filename, content_type: content_type)
  end

  # Exactly what a direct upload leaves behind: a row with the CLIENT's content type,
  # identified: nil, and the bytes put by the second request.
  def direct_uploaded(bytes, filename:, declared_type:)
    ActiveStorage::Blob.create_before_direct_upload!(
      filename: filename, byte_size: bytes.bytesize, checksum: OpenSSL::Digest::MD5.base64digest(bytes),
      content_type: declared_type
    ).tap { |blob| blob.service.upload(blob.key, StringIO.new(bytes), checksum: blob.checksum) }
  end

  def png_blob(size: 64) = uploaded(png_header + ('x' * size).b, filename: 'shot.png', content_type: 'image/png')
  def pdf_blob = uploaded(pdf_header + ('x' * 64).b, filename: 'ablauf.pdf', content_type: 'application/pdf')
  def pdf_declared_as_png = direct_uploaded(pdf_header + ('x' * 64).b, filename: 'shot.png', declared_type: 'image/png')

  def embed_html(*blobs, text: 'Schritt 1')
    blobs.map { |b| %(<action-text-attachment sgid="#{b.attachable_sgid}"></action-text-attachment>) }
         .join.prepend("<div>#{text}</div>")
  end

  def foreign_blob
    other_org = create(:organisation)
    other_project = create(:project, organisation: other_org)
    image = nil
    ActsAsTenant.with_tenant(other_org) do
      image = png_blob
      create(:ticket, project: other_project, organisation: other_org, content: embed_html(image))
    end
    image
  end

  shared_examples 'a carrier with the embed guard' do
    it 'saves a text with a 2 MB PNG and attaches it' do
      record = build_carrier(embed_html(png_blob(size: 2.megabytes)))

      expect(record.save).to be(true)
      expect(record.content.embeds.count).to eq(1)
    end

    it 'refuses a PDF embed with an error on the content' do
      record = build_carrier(embed_html(pdf_blob))

      expect(record.save).to be(false)
      expect(record.errors.added?(:content, :embed_not_an_image, filename: 'ablauf.pdf')).to be(true)
    end

    it 'refuses a PDF that the client declared as image/png (identifies the type itself)' do
      record = build_carrier(embed_html(pdf_declared_as_png))

      expect(record.save).to be(false)
      expect(record.errors.added?(:content, :embed_not_an_image, filename: 'shot.png')).to be(true)
    end

    it 'refuses an image above the size limit, naming the limit' do
      record = build_carrier(embed_html(png_blob(size: RichTextEmbeds::MAX_BYTE_SIZE + 1)))

      expect(record.save).to be(false)
      expect(record.errors.added?(:content, :embed_too_large, filename: 'shot.png', max: RichTextEmbeds.max_megabytes)).to be(true)
    end

    it 'refuses a blob that already belongs to a carrier of another organisation' do
      record = build_carrier(embed_html(foreign_blob))

      expect(record.save).to be(false)
      expect(record.errors.added?(:content, :embed_foreign_organisation, filename: 'shot.png')).to be(true)
    end

    it 'keeps a mixed text (one good image, one PDF) out entirely' do
      record = build_carrier(embed_html(png_blob, pdf_blob))

      expect(record.save).to be(false)
    end

    it 'reports a blob only once when it appears twice in the text' do
      blob = pdf_blob
      record = build_carrier(embed_html(blob, blob))

      expect(record.save).to be(false)
      expect(record.errors.where(:content, :embed_not_an_image).size).to eq(1)
    end

    describe 'delta: existing content is left alone (the four production tickets with a PDF tile)' do
      let!(:legacy) do
        # A PDF that was embedded before the rule existed, attached without validation.
        # Since Rails 8.1 the rich text collects its embeds in before_validation, which
        # save(validate: false) skips; validating the rich text alone attaches the PDF
        # without running the carrier's guard.
        # reload: Note bumps lock_version in an after_save (NoteVersion), the in-memory
        # copy would be stale for the next save.
        build_carrier(embed_html(pdf_blob)).tap { |r| r.content.validate }.tap { |r| r.save!(validate: false) }.reload
      end

      it 'still saves a title-only change' do
        legacy.title = 'Neuer Titel' if legacy.respond_to?(:title=)
        expect(legacy.save).to be(true)
      end

      it 'still saves a text change that keeps the old PDF' do
        legacy.content = embed_html(legacy.content.embeds.first.blob, text: 'Schritt 1, ergänzt')

        expect(legacy.save).to be(true)
      end

      it 'refuses a NEW PDF added next to the old one' do
        legacy.content = embed_html(legacy.content.embeds.first.blob, pdf_blob)

        expect(legacy.save).to be(false)
        expect(legacy.errors.where(:content, :embed_not_an_image).size).to eq(1)
      end

      # The Rails 8.1 trap: the rich text attaches its embeds while it validates itself,
      # so a guard that looked at content.embeds after that saw every new blob as old.
      it 'refuses a foreign-organisation image added to an existing text' do
        legacy.content = embed_html(legacy.content.embeds.first.blob, foreign_blob)

        expect(legacy.save).to be(false)
        expect(legacy.errors.added?(:content, :embed_foreign_organisation, filename: 'shot.png')).to be(true)
      end

      # Rails 8.1 reassigns content.embeds in memory on EVERY validation of the rich text.
      # A delta read from that association saw a blob that the first validation refused as
      # already attached on the second one (review of #918).
      describe 'repeated validation of the same object' do
        it 'refuses a new PDF on valid? followed by save' do
          legacy.content = embed_html(legacy.content.embeds.first.blob, pdf_blob)

          expect(legacy).not_to be_valid
          expect(legacy.save).to be(false)
          expect(legacy.errors.where(:content, :embed_not_an_image).size).to eq(1)
        end

        it 'refuses a foreign-organisation image on the second save too, and stores nothing' do
          blob = foreign_blob
          legacy.content = embed_html(legacy.content.embeds.first.blob, blob)

          expect(legacy.save).to be(false)
          expect(legacy.save).to be(false)
          expect(ActiveStorage::Attachment.where(record: legacy.content, name: 'embeds').pluck(:blob_id))
            .not_to include(blob.id)
        end

        it 'still warms the variant of a good image after valid? and save' do
          blob = png_blob
          legacy.content = embed_html(legacy.content.embeds.first.blob, blob)
          allow(RichTextEmbedVariantJob).to receive(:perform_later)

          legacy.valid?
          legacy.save!

          expect(RichTextEmbedVariantJob).to have_received(:perform_later).with(blob.id)
        end
      end

      it 'does not pay the identification for blobs that are already attached' do
        old_blob = legacy.content.embeds.first.blob
        allow(old_blob).to receive(:identify_without_saving)
        legacy.content = embed_html(old_blob, text: 'nur Text geändert')
        legacy.save

        expect(old_blob).not_to have_received(:identify_without_saving)
      end
    end

    describe 'dead sgid (image purged)' do
      def dead_embed_html
        blob = png_blob
        html = embed_html(blob)
        blob.purge
        html
      end

      it 'refuses a NEW dead sgid with a message instead of storing a placeholder' do
        record = build_carrier(dead_embed_html)

        expect(record.save).to be(false)
        expect(record.errors.added?(:content, :embed_missing)).to be(true)
      end

      it 'leaves an OLD dead sgid in place when the text is edited' do
        record = build_carrier(dead_embed_html).tap { |r| r.save!(validate: false) }.reload
        record.content = "#{record.content.body.to_html}<div>Nachtrag</div>"

        expect(record.save).to be(true)
      end
    end

    describe 'content attribute (Lexxy writes the rendered partial back into url-less nodes)' do
      it 'drops the redundant content from blob nodes but keeps it on mention nodes' do
        blob = png_blob
        mention_target = create(:note, project: project, organisation: organisation, title: 'Zielnotiz')
        html = %(<p>Schritt 1</p><p><action-text-attachment sgid="#{blob.attachable_sgid}" content="&lt;figure&gt;&lt;img src=&quot;https://x/rails/active_storage/representations/abc/shot.png&quot;&gt;&lt;/figure&gt;"></action-text-attachment></p>) \
               "<p><action-text-attachment sgid=\"#{mention_target.attachable_sgid}\" content-type=\"application/vnd.actiontext.mention\" content=\"Zielnotiz\"></action-text-attachment></p>"
        record = build_carrier(html)

        expect(record.save).to be(true)
        nodes = Nokogiri::HTML.fragment(record.reload.content.body.to_html).css('action-text-attachment')
        expect(nodes[0]['content']).to be_nil
        expect(nodes[0]['sgid']).to be_present
        expect(nodes[1]['content']).to eq('Zielnotiz')
        expect(record.content.embeds.count).to eq(1)
      end
    end

    describe 'url attribute (a signed_id without expiry, D9)' do
      it 'strips url and href from every attachment node before saving' do
        blob = png_blob
        html = %(<div>Schritt 1</div><action-text-attachment sgid="#{blob.attachable_sgid}" url="https://x/rails/active_storage/blobs/redirect/abc/shot.png" href="https://x/y" content-type="image/png" filename="shot.png"></action-text-attachment>)
        record = build_carrier(html)

        expect(record.save).to be(true)
        node = Nokogiri::HTML.fragment(record.reload.content.body.to_html).at_css('action-text-attachment')
        expect(node['url']).to be_nil
        expect(node['href']).to be_nil
        expect(node['sgid']).to be_present
        expect(node['filename']).to eq('shot.png')
      end
    end
  end

  describe 'Ticket' do
    def build_carrier(html) = build(:ticket, project: project, organisation: organisation, content: html)

    it_behaves_like 'a carrier with the embed guard'
  end

  describe 'Note' do
    def build_carrier(html) = build(:note, project: project, organisation: organisation, content: html)

    it_behaves_like 'a carrier with the embed guard'
  end

  describe 'Post' do
    let(:ticket) { create(:ticket, project: project, organisation: organisation) }

    def build_carrier(html) = build(:post, ticket: ticket, organisation: organisation, content: html)

    it_behaves_like 'a carrier with the embed guard'
  end

  describe 'organisation rule, edge cases (D6)' do
    def ticket_with(html) = build(:ticket, project: project, organisation: organisation, content: html)

    it 'treats a blob attached to a carrier without organisation (user data export) as foreign' do
      blob = png_blob
      export = create(:user_data_export)
      export.archive.attach(blob)

      record = ticket_with(embed_html(blob))
      expect(record.save).to be(false)
      expect(record.errors.added?(:content, :embed_foreign_organisation, filename: 'shot.png')).to be(true)
    end

    it 'allows a blob that hangs on a document of the same organisation' do
      blob = png_blob
      document = create(:ticket_document, organisation: organisation)
      document.ticket_document_file.attach(blob)

      record = ticket_with(embed_html(blob))
      expect(record.save).to be(true)
    end

    it 'treats a reference whose carrier is already gone as foreign, without a nil crash' do
      blob = png_blob
      carrier = create(:ticket, project: project, organisation: organisation, content: embed_html(blob))
      carrier.content.embeds.first.record.delete # orphan the RichText row itself

      record = ticket_with(embed_html(blob))
      expect { record.save }.not_to raise_error
      expect(record.save).to be(false)
    end
  end
end
