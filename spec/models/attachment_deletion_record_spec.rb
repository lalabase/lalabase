# frozen_string_literal: true

require 'rails_helper'

# What: the reading side of the deletion register (AVV § 12 Abs. 7).
# Type: Model spec.
# Why:  organisations_in_register feeds the audit filter, and it is the one
#       place where reading from the register instead of from the organisations
#       table is load-bearing rather than a style choice. The rename case is
#       here too: it has no visible symptom in the register itself, only a
#       duplicated entry in the filter that nobody would call a defect.
RSpec.describe AttachmentDeletionRecord do
  def record(organisation_id: SecureRandom.uuid, organisation_name: 'Muster GmbH', **attrs)
    described_class.create!(
      organisation_id: organisation_id,
      organisation_name: organisation_name,
      storage_key: SecureRandom.hex(8),
      filename: 'Vertrag.pdf',
      deleted_at: 1.day.ago,
      **attrs
    )
  end

  describe '.organisations_in_register' do
    it 'lists an organisation that no longer exists' do
      gone = SecureRandom.uuid
      record(organisation_id: gone, organisation_name: 'Aufgeloest GmbH')

      expect(::Organisation.exists?(gone)).to be(false)
      expect(described_class.organisations_in_register).to eq([[gone, 'Aufgeloest GmbH']])
    end

    # One entry per organisation, carrying the name last seen. Two entries would
    # offer the same filter twice and read as two customers.
    it 'collapses a renamed organisation to its most recent name' do
      id = SecureRandom.uuid
      record(organisation_id: id, organisation_name: 'Alter Name', deleted_at: 2.days.ago)
      record(organisation_id: id, organisation_name: 'Neuer Name', deleted_at: 1.hour.ago)

      expect(described_class.organisations_in_register).to eq([[id, 'Neuer Name']])
    end

    it 'sorts by name, case-insensitively' do
      zeta = SecureRandom.uuid
      alpha = SecureRandom.uuid
      record(organisation_id: zeta, organisation_name: 'zeta GmbH')
      record(organisation_id: alpha, organisation_name: 'Alpha GmbH')

      expect(described_class.organisations_in_register.map(&:last)).to eq(['Alpha GmbH', 'zeta GmbH'])
    end

    # Export archives span all of a user's organisations and carry none. They
    # belong in the totals, never in a per-organisation answer.
    it 'omits entries without an organisation' do
      record(organisation_id: nil, organisation_name: nil)

      expect(described_class.organisations_in_register).to be_empty
      expect(described_class.without_organisation.count).to eq(1)
    end
  end

  describe '.register_started_at' do
    it 'is the oldest entry, not the oldest deletion' do
      entry = record(deleted_at: 5.years.ago)
      entry.update_column(:created_at, Time.zone.local(2026, 8, 5, 12, 0))

      expect(described_class.register_started_at.to_date).to eq(Date.new(2026, 8, 5))
    end

    it 'is nil while the register is empty' do
      expect(described_class.register_started_at).to be_nil
    end
  end
end
