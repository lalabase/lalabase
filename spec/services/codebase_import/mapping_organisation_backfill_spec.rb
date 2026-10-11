# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CodebaseImport::MappingOrganisationBackfill do
  let(:importing) { create(:organisation) }
  let(:other) { create(:organisation) }
  let(:importer) { create(:user) }

  def within(organisation, &)
    ActsAsTenant.with_tenant(organisation, &)
  end

  def member(user, organisation)
    within(organisation) { create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation)) }
    user
  end

  def import_file_in(organisation)
    within(organisation) do
      create(:codebase_import_file, organisation: organisation, user: importer,
                                    project: create(:project, organisation: organisation), file_type: 'tickets', status: 'processed')
    end
  end

  # Rows as they were before the organisation column existed.
  def legacy_mapping(entity_type, local_id, codebase_id = SecureRandom.hex(4))
    ActsAsTenant.without_tenant do
      CodebaseImportMapping.insert_all!([{ codebase_id: codebase_id, local_id: local_id, entity_type: entity_type, mapping_data: {} }])
    end
    codebase_id
  end

  def organisation_of(codebase_id, entity_type)
    ActsAsTenant.without_tenant do
      CodebaseImportMapping.where(codebase_id: codebase_id, entity_type: entity_type).pluck(:organisation_id)
    end
  end

  let!(:records) do
    [importing, other].each { |organisation| import_file_in(organisation) }
    within(importing) do
      project = create(:project, organisation: importing)
      ticket = create(:ticket, organisation: importing, project: project, creator: importer)
      booking = create(:time_session, organisation: importing, project: project, creator: member(importer, importing))
      { ticket: ticket, booking: booking, project: project }
    end.merge(group: within(other) { create(:time_session_group, organisation: other, creator: importer) })
  end

  let!(:codebase_ids) do
    only_here = member(create(:user), importing)
    in_both = member(member(create(:user), importing), other)
    {
      ticket: legacy_mapping('Ticket', records[:ticket].id),
      booking: legacy_mapping('TimeSession', records[:booking].id),
      group: legacy_mapping('TimeSessionGroup', records[:group].id),
      only_here: legacy_mapping('User', only_here.id),
      in_both: legacy_mapping('User', in_both.id),
      orphan: legacy_mapping('Ticket', SecureRandom.uuid)
    }
  end

  it 'reports without writing in a dry run' do
    report = described_class.call(dry_run: true)

    expect(report.assigned).to eq('Ticket' => 1, 'TimeSession' => 1, 'TimeSessionGroup' => 1, 'User' => 1)
    expect(organisation_of(codebase_ids[:ticket], 'Ticket')).to eq([nil])
  end

  it 'assigns each mapping to the organisation of its record and leaves the ambiguous ones' do
    report = described_class.call(dry_run: false)

    expect(organisation_of(codebase_ids[:ticket], 'Ticket')).to eq([importing.id])
    expect(organisation_of(codebase_ids[:booking], 'TimeSession')).to eq([importing.id])
    expect(organisation_of(codebase_ids[:group], 'TimeSessionGroup')).to eq([other.id])
    expect(organisation_of(codebase_ids[:only_here], 'User')).to eq([importing.id])
    expect(organisation_of(codebase_ids[:in_both], 'User')).to eq([nil])
    expect(report.unassigned).to eq('Ticket' => 1, 'User' => 1)
    expect(described_class.call(dry_run: false).assigned.values).to all(eq(0))
  end

  it 'reports imported bookings linked to another organisation, without changing them' do
    records[:booking].update_columns(time_session_group_id: records[:group].id)

    report = described_class.call(dry_run: false)

    expect(report.foreign_links['time_session_group']).to eq([records[:booking].id])
    expect(report.foreign_links['ticket']).to be_empty
    expect(records[:booking].reload.time_session_group_id).to eq(records[:group].id)
  end
end
