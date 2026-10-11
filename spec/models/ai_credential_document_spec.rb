# frozen_string_literal: true

require 'rails_helper'

# What this protects: a document is EVIDENCE for a claim the operator makes to
# their own customers. It has to stay findable (locator), reachable (file or
# url) and groupable across its versions (document_key) — otherwise the claim is
# unverifiable a year later, which is exactly the state this feature replaces.
RSpec.describe AiCredentialDocument do
  describe 'document_key' do
    # Without normalisation a typo splits one paper's history in two, and the
    # operator sees two half-histories with nothing failing.
    it 'normalises case and whitespace' do
      document = create(:ai_credential_document, document_key: '  SST ')

      expect(document.document_key).to eq('sst')
    end

    it 'is required' do
      expect(build(:ai_credential_document, document_key: ' ')).not_to be_valid
    end

    # Two versions of the same paper on the same day make "the current version"
    # ambiguous — the DB index says so, and the model says it readably.
    it 'is unique per credential and date' do
      first = create(:ai_credential_document)
      duplicate = build(:ai_credential_document, ai_credential: first.ai_credential,
                                                 document_key: first.document_key,
                                                 valid_from: first.valid_from)

      expect(duplicate).not_to be_valid
    end

    it 'allows the same paper on another date — that is a new version' do
      first = create(:ai_credential_document)
      newer = build(:ai_credential_document, ai_credential: first.ai_credential,
                                             document_key: first.document_key,
                                             valid_from: first.valid_from + 90.days)

      expect(newer).to be_valid
    end

    it 'allows the same paper on another credential' do
      create(:ai_credential_document, document_key: 'sst')

      expect(build(:ai_credential_document, document_key: 'sst')).to be_valid
    end
  end

  describe 'versions may overlap, unlike assessed contracts' do
    # The deliberate difference to AiCredentialContract: a provider publishes a
    # new version while the old one still governs existing agreements, so both
    # remain usable as evidence. EffectiveDating's no-overlap rule would be
    # plainly wrong here.
    it 'accepts several versions without a validity window' do
      credential = create(:ai_credential)
      create(:ai_credential_document, ai_credential: credential, valid_from: Date.current - 200.days)
      create(:ai_credential_document, ai_credential: credential, valid_from: Date.current - 100.days)

      expect(credential.documents.count).to eq(2)
    end
  end

  describe '.current_version' do
    let(:credential) { create(:ai_credential) }

    it 'returns the newest version that has already started' do
      create(:ai_credential_document, ai_credential: credential, valid_from: Date.current - 200.days)
      newest = create(:ai_credential_document, ai_credential: credential,
                                               valid_from: Date.current - 10.days)
      create(:ai_credential_document, ai_credential: credential, valid_from: Date.current + 30.days)

      expect(described_class.current_version(credential.documents)).to eq(newest)
    end

    it 'returns nil when every version lies in the future' do
      create(:ai_credential_document, ai_credential: credential, valid_from: Date.current + 30.days)

      expect(described_class.current_version(credential.documents)).to be_nil
    end
  end

  describe '#evidence?' do
    # A row with neither file nor link is a note, not a document.
    it 'is true with a url alone' do
      expect(build(:ai_credential_document).evidence?).to be(true)
    end

    it 'is false without url and without file' do
      expect(build(:ai_credential_document, url: nil).evidence?).to be(false)
    end
  end

  # The document list renders `url` through `link_to`, and that does NOT filter the
  # scheme. A stored javascript: URL thus becomes a click payload on the
  # admin page, in its own session. The rule sits here and not in the
  # controller, because the operator types this field in two ways.
  describe 'url validation' do
    it 'accepts https' do
      expect(build(:ai_credential_document, url: 'https://example.test/sst')).to be_valid
    end

    it 'accepts plain http' do
      expect(build(:ai_credential_document, url: 'http://example.test/sst')).to be_valid
    end

    it 'accepts no url at all — an attached PDF is evidence too' do
      expect(build(:ai_credential_document, url: nil)).to be_valid
    end

    it 'refuses a javascript: URL' do
      document = build(:ai_credential_document, url: 'javascript:alert(1)')
      message = I18n.t('activerecord.errors.models.ai_credential_document.attributes.url.not_http_url')

      expect(document).not_to be_valid
      expect(document.errors[:url]).to include(message)
    end

    # data: carries a whole HTML page: the same class as javascript:, just
    # with a different scheme. An allowlist covers both, a blocklist does not.
    it 'refuses a data: URL' do
      expect(build(:ai_credential_document, url: 'data:text/html,<script>alert(1)</script>')).not_to be_valid
    end

    # Scheme-relative inherits the scheme of the page. Harmless, but a piece of evidence
    # should NAME a foreign paper, not point at our own app.
    it 'refuses a scheme-relative URL' do
      expect(build(:ai_credential_document, url: '//example.test/sst')).not_to be_valid
    end
  end

  describe 'file validation' do
    def attach(document, io:, filename:, content_type:)
      document.file.attach(io: io, filename: filename, content_type: content_type)
      document
    end

    it 'accepts a PDF' do
      document = attach(build(:ai_credential_document), io: StringIO.new('%PDF-1.4'),
                                                        filename: 'terms.pdf',
                                                        content_type: 'application/pdf')

      expect(document).to be_valid
    end

    it 'rejects anything that is not a PDF' do
      document = attach(build(:ai_credential_document), io: StringIO.new('nope'),
                                                        filename: 'terms.txt',
                                                        content_type: 'text/plain')

      expect(document).not_to be_valid
      expect(document.errors[:file]).to be_present
    end

    it 'rejects a file above the size limit' do
      oversized = 'x' * (described_class::MAX_FILE_SIZE + 1)
      document = attach(build(:ai_credential_document), io: StringIO.new(oversized),
                                                        filename: 'huge.pdf',
                                                        content_type: 'application/pdf')

      expect(document).not_to be_valid
    end

    # The upload controller puts full_messages straight into the flash. An
    # untranslated symbol lands there as "Translation missing: …", and
    # `be_present` above cannot tell the two apart — that is how it shipped.
    it 'names the reason in both locales' do
      not_pdf = attach(build(:ai_credential_document), io: StringIO.new('nope'),
                                                       filename: 'terms.txt',
                                                       content_type: 'text/plain')
      not_pdf.validate

      expect(not_pdf.errors.full_messages.first).to eq('PDF muss eine PDF-Datei sein')

      I18n.with_locale(:en) do
        oversized = attach(build(:ai_credential_document),
                           io: StringIO.new('x' * (described_class::MAX_FILE_SIZE + 1)),
                           filename: 'huge.pdf', content_type: 'application/pdf')
        oversized.validate

        # The limit interpolates in megabytes, not bytes — a raw 26214400 in the
        # flash would be technically true and practically useless.
        expect(oversized.errors.full_messages.first).to eq('PDF is too large (max. 25 MB)')
      end
    end
  end

  describe 'deletion' do
    # A document a version cites is exactly the evidence this feature exists
    # for. Deleting it would leave an assessment whose basis is gone.
    it 'refuses to delete a document that supports an assessment' do
      document = create(:ai_credential_document)
      contract = create(:ai_credential_contract, ai_credential: document.ai_credential)
      contract.documents << document

      expect(document.destroy).to be(false)
      expect(described_class.exists?(document.id)).to be(true)
    end

    it 'deletes an uncited document' do
      document = create(:ai_credential_document)

      expect { document.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
