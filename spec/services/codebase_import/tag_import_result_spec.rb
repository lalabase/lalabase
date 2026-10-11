# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CodebaseImport::TagImportResult, type: :value_object do
  describe '#initialize' do
    it 'sets default values correctly' do
      result = described_class.new

      expect(result.total_tags_found).to eq(0)
      expect(result.new_tags_created).to eq(0)
      expect(result.existing_tags_reused).to eq(0)
      expect(result.total_taggings_created).to eq(0)
      expect(result.errors).to eq([])
      expect(result.processing_time).to be_nil
    end

    it 'accepts custom values' do
      errors = ['Error 1', 'Error 2']
      processing_time = 5.seconds

      result = described_class.new(
        total_tags_found: 10,
        new_tags_created: 7,
        existing_tags_reused: 3,
        total_taggings_created: 25,
        errors: errors,
        processing_time: processing_time
      )

      expect(result.total_tags_found).to eq(10)
      expect(result.new_tags_created).to eq(7)
      expect(result.existing_tags_reused).to eq(3)
      expect(result.total_taggings_created).to eq(25)
      expect(result.errors).to eq(errors)
      expect(result.processing_time).to eq(processing_time)
    end
  end

  describe '#success?' do
    it 'returns true when no errors' do
      result = described_class.new(total_tags_found: 5)
      expect(result.success?).to be true
    end

    it 'returns false when errors exist' do
      result = described_class.new(errors: ['Error'])
      expect(result.success?).to be false
    end
  end

  describe '#partial_success?' do
    it 'returns true when tags found but errors exist' do
      result = described_class.new(total_tags_found: 5, errors: ['Error'])
      expect(result.partial_success?).to be true
    end

    it 'returns false when no tags found' do
      result = described_class.new(total_tags_found: 0, errors: ['Error'])
      expect(result.partial_success?).to be false
    end

    it 'returns false when no errors' do
      result = described_class.new(total_tags_found: 5)
      expect(result.partial_success?).to be false
    end
  end

  describe '#failure?' do
    it 'returns true when no tags found' do
      result = described_class.new(total_tags_found: 0)
      expect(result.failure?).to be true
    end

    it 'returns true when errors exist and nothing was created' do
      result = described_class.new(
        total_tags_found: 5,
        new_tags_created: 0,
        total_taggings_created: 0,
        errors: ['Error']
      )
      expect(result.failure?).to be true
    end

    it 'returns false when successful' do
      result = described_class.new(
        total_tags_found: 5,
        new_tags_created: 2,
        total_taggings_created: 10
      )
      expect(result.failure?).to be false
    end
  end

  describe '#has_errors?' do
    it 'returns true when errors exist' do
      result = described_class.new(errors: ['Error'])
      expect(result.has_errors?).to be true
    end

    it 'returns false when no errors' do
      result = described_class.new
      expect(result.has_errors?).to be false
    end
  end

  describe '#to_summary_hash' do
    it 'converts to hash format correctly' do
      processing_time = 2.5.seconds
      result = described_class.new(
        total_tags_found: 10,
        new_tags_created: 7,
        existing_tags_reused: 3,
        total_taggings_created: 25,
        errors: ['Error 1', 'Error 2', 'Error 3', 'Error 4', 'Error 5', 'Error 6'],
        processing_time: processing_time
      )

      hash = result.to_summary_hash

      expect(hash).to eq({
                           total_tags_found: 10,
                           new_tags_created: 7,
                           existing_tags_reused: 3,
                           total_taggings_created: 25,
                           success: false, # false because there are errors
                           error_count: 6,
                           errors: ['Error 1', 'Error 2', 'Error 3', 'Error 4', 'Error 5'], # Limited to 5
                           processing_time_ms: 2500.0
                         })
    end

    it 'handles nil processing time' do
      result = described_class.new(total_tags_found: 5)
      hash = result.to_summary_hash

      expect(hash[:processing_time_ms]).to be_nil
    end
  end

  describe '.from_summary_hash' do
    it 'creates result from hash' do
      hash = {
        total_tags_found: 10,
        new_tags_created: 7,
        existing_tags_reused: 3,
        total_taggings_created: 25,
        errors: ['Error 1'],
        processing_time_ms: 1500.0
      }

      result = described_class.from_summary_hash(hash)

      expect(result.total_tags_found).to eq(10)
      expect(result.new_tags_created).to eq(7)
      expect(result.existing_tags_reused).to eq(3)
      expect(result.total_taggings_created).to eq(25)
      expect(result.errors).to eq(['Error 1'])
      expect(result.processing_time).to eq(1.5.seconds)
    end

    it 'handles nil hash' do
      result = described_class.from_summary_hash(nil)

      expect(result.total_tags_found).to eq(0)
      expect(result.new_tags_created).to eq(0)
    end

    it 'handles empty hash' do
      result = described_class.from_summary_hash({})

      expect(result.total_tags_found).to eq(0)
      expect(result.new_tags_created).to eq(0)
    end
  end

  describe '#merge' do
    it 'combines two results correctly' do
      result1 = described_class.new(
        total_tags_found: 5,
        new_tags_created: 3,
        existing_tags_reused: 2,
        total_taggings_created: 10,
        errors: ['Error 1'],
        processing_time: 1.second
      )

      result2 = described_class.new(
        total_tags_found: 8,
        new_tags_created: 4,
        existing_tags_reused: 4,
        total_taggings_created: 15,
        errors: ['Error 2'],
        processing_time: 2.seconds
      )

      merged = result1.merge(result2)

      expect(merged.total_tags_found).to eq(8) # Takes maximum
      expect(merged.new_tags_created).to eq(7) # Sums up
      expect(merged.existing_tags_reused).to eq(6) # Sums up
      expect(merged.total_taggings_created).to eq(25) # Sums up
      expect(merged.errors).to eq(['Error 1', 'Error 2'])
      expect(merged.processing_time).to eq(3.seconds)
    end

    it 'handles nil result' do
      result1 = described_class.new(total_tags_found: 5)
      merged = result1.merge(nil)

      expect(merged).to eq(result1)
    end

    it 'handles nil processing times' do
      result1 = described_class.new(processing_time: 1.second)
      result2 = described_class.new(processing_time: nil)

      merged = result1.merge(result2)
      expect(merged.processing_time).to eq(1.second)
    end
  end

  describe '#summary_message' do
    it 'returns success message for successful import' do
      result = described_class.new(
        new_tags_created: 5,
        existing_tags_reused: 3,
        total_taggings_created: 20
      )

      message = result.summary_message
      expect(message).to eq('Tag-Import erfolgreich: 5 neue Tags erstellt, 3 bestehende Tags wiederverwendet, 20 Tag-Zuweisungen erstellt')
    end

    it 'returns partial success message' do
      result = described_class.new(
        total_tags_found: 5,
        new_tags_created: 3,
        errors: ['Error 1']
      )

      message = result.summary_message
      expect(message).to eq('Tag-Import teilweise erfolgreich: 1 Fehler aufgetreten')
    end

    it 'returns failure message' do
      result = described_class.new(
        total_tags_found: 0,
        errors: ['Error 1', 'Error 2']
      )

      message = result.summary_message
      expect(message).to eq('Tag-Import fehlgeschlagen: 2 Fehler aufgetreten')
    end

    it 'handles case with no tags found' do
      result = described_class.new

      message = result.summary_message
      expect(message).to eq('Keine Tags gefunden zum Import')
    end
  end

  describe '#debug_info' do
    it 'returns structured debug information' do
      result = described_class.new(
        total_tags_found: 10,
        new_tags_created: 7,
        existing_tags_reused: 3,
        total_taggings_created: 25,
        errors: ['Error 1'],
        processing_time: 1.5.seconds
      )

      debug_info = result.debug_info

      expect(debug_info).to include(
        status: 'partial',
        stats: {
          total_found: 10,
          new_created: 7,
          existing_reused: 3,
          taggings_created: 25
        },
        errors: ['Error 1'],
        processing_time: 1.5.seconds
      )
    end

    it 'identifies successful status' do
      result = described_class.new(total_tags_found: 5)
      expect(result.debug_info[:status]).to eq('success')
    end

    it 'identifies failed status' do
      result = described_class.new(total_tags_found: 0, errors: ['Error'])
      expect(result.debug_info[:status]).to eq('failed')
    end
  end
end
