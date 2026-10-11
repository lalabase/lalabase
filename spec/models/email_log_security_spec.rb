# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmailLog, type: :model do
  describe 'Security Features' do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user, organisation: organisation) }
    let(:notification) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation)
      end
    end
    let(:email_log) do
      ActsAsTenant.with_tenant(organisation) do
        create(:email_log, notification: notification, organisation: organisation)
      end
    end

    describe '#safe_decompress' do
      context 'with valid gzip data' do
        it 'decompresses content successfully' do
          original = 'This is test content for compression'
          compressed = ActiveSupport::Gzip.compress(original)

          result = email_log.send(:safe_decompress, compressed)
          expect(result).to eq(original)
        end

        it 'handles empty strings' do
          original = ''
          compressed = ActiveSupport::Gzip.compress(original)

          result = email_log.send(:safe_decompress, compressed)
          expect(result).to eq(original)
        end
      end

      context 'with malicious payloads' do
        it 'rejects zip bombs (excessive decompressed size)' do
          # Create a string that compresses very well (zip bomb simulation)
          bomb_content = 'A' * (EmailLog::MAX_DECOMPRESSED_SIZE + 1000)
          compressed = ActiveSupport::Gzip.compress(bomb_content)

          result = email_log.send(:safe_decompress, compressed)
          expect(result).to be_nil
        end

        it 'rejects oversized compressed data' do
          # Simulate oversized compressed data
          oversized = 'X' * (EmailLog::MAX_COMPRESSED_SIZE + 1)

          result = email_log.send(:safe_decompress, oversized)
          expect(result).to be_nil
        end

        it 'handles corrupted gzip data gracefully' do
          corrupted_data = "corrupted\x00gzip\xFFdata"

          result = email_log.send(:safe_decompress, corrupted_data)
          expect(result).to be_nil
        end

        it 'handles truncated gzip streams' do
          original = 'Valid content'
          compressed = ActiveSupport::Gzip.compress(original)
          # Truncate more aggressively to ensure it's invalid
          truncated = compressed[0...10] # Keep only first 10 bytes (headers incomplete)

          result = email_log.send(:safe_decompress, truncated)
          expect(result).to be_nil
        end

        it 'prevents memory exhaustion with controlled limits' do
          # Test that we don't read more than MAX_DECOMPRESSED_SIZE
          large_content = 'B' * EmailLog::MAX_DECOMPRESSED_SIZE
          compressed = ActiveSupport::Gzip.compress(large_content)

          result = email_log.send(:safe_decompress, compressed)
          expect(result).to eq(large_content)
          expect(result.bytesize).to eq(EmailLog::MAX_DECOMPRESSED_SIZE)
        end
      end

      context 'with edge cases' do
        it 'handles nil input' do
          result = email_log.send(:safe_decompress, nil)
          expect(result).to be_nil
        end

        it 'handles empty string input' do
          result = email_log.send(:safe_decompress, '')
          expect(result).to be_nil
        end

        it 'handles binary data that is not gzip' do
          binary_data = "\x89PNG\r\n\x1a\n" # PNG header

          result = email_log.send(:safe_decompress, binary_data)
          expect(result).to be_nil
        end
      end
    end

    describe '#body_html decompression' do
      it 'automatically decompresses stored HTML' do
        html_content = '<html><body><h1>Test Email</h1></body></html>'
        email_log.body_html = html_content
        email_log.save!

        # Verify it's stored compressed
        expect(email_log.body_html_compressed).not_to eq(html_content)

        # Verify retrieval works
        reloaded = ActsAsTenant.with_tenant(organisation) do
          EmailLog.find(email_log.id)
        end
        expect(reloaded.body_html).to eq(html_content)
      end

      it 'handles very large HTML content' do
        # Generate large HTML (just under limit)
        large_html = '<html><body>' + ('X' * (EmailLog::MAX_DECOMPRESSED_SIZE - 100)) + '</body></html>'

        email_log.body_html = large_html
        email_log.save!

        reloaded = ActsAsTenant.with_tenant(organisation) do
          EmailLog.find(email_log.id)
        end
        expect(reloaded.body_html).to eq(large_html)
      end

      it 'returns nil for corrupted compressed data' do
        email_log.update_column(:body_html_compressed, "corrupted\x00data")

        expect(email_log.reload.body_html).to be_nil
      end
    end
  end
end
