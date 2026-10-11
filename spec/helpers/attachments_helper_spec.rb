# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AttachmentsHelper, type: :helper do
  describe '#attachment_file_icon' do
    # The else-branch file chip uses this to signal the file *kind* — so a user reading a
    # post can tell "this is a PDF link", not just "this is a link" (the reported gap).
    # content_type is delegated through ActiveStorage via method_missing, so a verifying
    # double rejects it; the helper only reads #content_type, so a plain stub is enough.
    def icon_for(content_type)
      file = double('attachment', content_type: content_type)
      helper.attachment_file_icon(file)
    end

    it 'maps a PDF to the PDF icon' do
      expect(icon_for('application/pdf')).to eq('bi-file-earmark-pdf')
    end

    it 'maps images to the image icon' do
      expect(icon_for('image/png')).to eq('bi-file-earmark-image')
      expect(icon_for('image/jpeg')).to eq('bi-file-earmark-image')
    end

    it 'maps office docs and sheets to their icons' do
      expect(icon_for('application/vnd.openxmlformats-officedocument.wordprocessingml.document'))
        .to eq('bi-file-earmark-word')
      expect(icon_for('text/csv')).to eq('bi-file-earmark-spreadsheet')
    end

    it 'maps archives to the zip icon' do
      expect(icon_for('application/zip')).to eq('bi-file-earmark-zip')
    end

    it 'falls back to the generic file icon for unknown types' do
      expect(icon_for('application/octet-stream')).to eq('bi-file-earmark')
      expect(icon_for('')).to eq('bi-file-earmark')
    end
  end

  # The document's attribute row names the kind (S3 of doc/dokumentansicht_plan.md);
  # the word and the icon come from the ONE table, so they cannot disagree.
  describe '#attachment_file_kind_word' do
    def word_for(content_type)
      helper.attachment_file_kind_word(double('attachment', content_type: content_type))
    end

    it 'names the kind in the reader\'s language' do
      expect(word_for('application/pdf')).to eq(I18n.t('views.shared.file_kinds.pdf'))
      expect(word_for('image/png')).to eq(I18n.t('views.shared.file_kinds.image'))
      expect(word_for('text/csv')).to eq(I18n.t('views.shared.file_kinds.sheet'))
      expect(word_for('text/plain')).to eq(I18n.t('views.shared.file_kinds.text'))
      expect(word_for('application/octet-stream')).to eq(I18n.t('views.shared.file_kinds.file'))
    end

    it 'has a word for every kind the icon table knows' do
      AttachmentsHelper::FILE_KIND_ICONS.each_key do |kind|
        expect(I18n.t("views.shared.file_kinds.#{kind}", raise: true)).to be_present
      end
    end
  end
end
