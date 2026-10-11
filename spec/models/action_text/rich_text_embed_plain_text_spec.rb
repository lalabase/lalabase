# frozen_string_literal: true

require 'rails_helper'

# What:  Everything that reads a rich text as TEXT (search index, embeddings, mails)
#        sees an image embed as a filename marker, never as markup, never as a link.
# Type:  Model guard plus a static guard over the mailer views (spike S5, 2026-08-23).
# Why:   The design doc asked to confirm that embed markup does not disturb indexers and
#        normalizers, and that mails never ship image links (F11). All of them go through
#        ActionText#to_plain_text, which renders an attachment as "[filename]"; this file
#        pins that contract for the three carriers and pins that no mailer view bypasses
#        to_plain_text. A mailer rendering `.content` as HTML would ship signed 15-minute
#        links into mailboxes, where they outlive the signature and break.
RSpec.describe 'Rich text embed as plain text' do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def png_blob
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("\x89PNG\r\n\x1a\n#{'x' * 64}"), filename: 'ablauf.png', content_type: 'image/png'
    )
  end

  def embed_html(blob) = %(<div>Schritt 1</div><action-text-attachment sgid="#{blob.attachable_sgid}"></action-text-attachment><div>Schritt 2</div>)

  shared_examples 'plain text without markup' do
    it 'keeps the surrounding text and marks the image by filename only' do
      expect(plain_text).to include('Schritt 1').and include('Schritt 2')
      expect(plain_text).to include('[ablauf.png]')
      expect(plain_text).not_to include('<action-text-attachment')
      expect(plain_text).not_to include('sgid')
      expect(plain_text).not_to include('/rails/active_storage')
    end
  end

  describe 'Ticket#plain_text_version (embeddings)' do
    let(:plain_text) { create(:ticket, project: project, organisation: organisation, content: embed_html(png_blob)).plain_text_version }

    it_behaves_like 'plain text without markup'
  end

  describe 'Note#plain_text_version (search, embeddings)' do
    let(:plain_text) { create(:note, project: project, organisation: organisation, content: embed_html(png_blob)).plain_text_version }

    it_behaves_like 'plain text without markup'
  end

  describe 'Post#plain_text_version (search, embeddings)' do
    let(:ticket) { create(:ticket, project: project, organisation: organisation) }
    let(:plain_text) { create(:post, ticket: ticket, organisation: organisation, content: embed_html(png_blob)).plain_text_version }

    it_behaves_like 'plain text without markup'
  end

  describe 'mailer views' do
    # Every reference to a rich-text body in a mailer view must go through to_plain_text.
    # `content` is the only has_rich_text attribute in the app (Ticket, Post, Note);
    # Document#description is a plain column and deliberately not matched. Excludes the
    # names that merely share the prefix (content_type) and the presence checks.
    it 'never render a rich text as HTML' do
      declared = Dir[Rails.root.join('app/models/**/*.rb')].flat_map { |f| File.read(f).scan(/has_rich_text :(\w+)/).flatten }
      expect(declared.uniq).to eq(['content'])

      offenders = Dir[Rails.root.join('app/views/**/*mailer*/**/*.erb')].flat_map do |file|
        File.readlines(file).each_with_index.filter_map do |line, i|
          next unless line.match?(/\.content\b/)
          next if line.match?(/content_type|\.present\?|to_plain_text|respond_to\?/)

          "#{file.delete_prefix(Rails.root.to_s)}:#{i + 1}: #{line.strip}"
        end
      end

      expect(offenders).to be_empty
    end
  end
end
