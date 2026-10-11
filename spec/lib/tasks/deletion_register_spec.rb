# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: the command-line audit answer for the deletion register
#       (AVV § 12 Abs. 7, L3 of doc/loeschverzeichnis_plan.md).
# Type: Rake task spec.
# Why:  This output gets pasted into a letter to a controller. Two of its lines
#       are contract text and are the ones a well-meaning cleanup would drop as
#       noise: since when the register is kept, and how many entries carry no
#       confirmed backup expiry. Both are pinned here.
#
#       Also pinned: the task never writes. It is an answer, not a maintenance
#       run, and the neighbouring jobs in this namespace do delete.
RSpec.describe 'deletion_register tasks' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('deletion_register:report')
  end

  before { Rake::Task['deletion_register:report'].reenable }

  after { ENV.delete('ORG') }

  def record(organisation_id: SecureRandom.uuid, organisation_name: 'Muster GmbH', **attrs)
    AttachmentDeletionRecord.create!(
      organisation_id: organisation_id,
      organisation_name: organisation_name,
      storage_key: SecureRandom.hex(8),
      filename: 'Vertrag.pdf',
      deleted_at: 1.day.ago,
      **attrs
    )
  end

  def run_report
    output = StringIO.new
    original = $stdout
    $stdout = output
    Rake::Task['deletion_register:report'].invoke
    output.string
  ensure
    $stdout = original
  end

  it 'names the date the register started' do
    entry = record
    entry.update_column(:created_at, Time.zone.local(2026, 8, 5, 12, 0))

    expect(run_report).to include('Verzeichnis gefuehrt seit:   2026-08-05')
  end

  it 'says so when the register is still empty' do
    output = run_report

    expect(output).to include('noch kein Eintrag vorhanden')
    expect(output).to include('Keine Eintraege.')
  end

  it 'reports entries without a backup confirmation as their own number' do
    record(backup_deleted_at: nil)
    record(backup_deleted_at: 1.hour.ago, backup_expires_at: Date.current)

    output = run_report

    expect(output).to include('Eintraege gesamt:            2')
    expect(output).to include('davon ohne Nachtrag:         1')
  end

  it 'names the files that were deleted' do
    record(filename: 'Kuendigung.pdf', organisation_name: 'Beispiel AG')

    output = run_report

    expect(output).to include('Kuendigung.pdf')
    expect(output).to include('Beispiel AG')
  end

  it 'marks an entry whose confirmation is still missing in its row' do
    record(backup_deleted_at: nil)

    expect(run_report).to include('Nachtrag ausstehend')
  end

  describe 'with ORG' do
    it 'restricts the answer to that organisation' do
      mine = SecureRandom.uuid
      record(organisation_id: mine, organisation_name: 'Meine GmbH', filename: 'meins.pdf')
      record(organisation_id: SecureRandom.uuid, organisation_name: 'Fremde GmbH', filename: 'fremd.pdf')
      ENV['ORG'] = mine

      output = run_report

      expect(output).to include('meins.pdf')
      expect(output).not_to include('fremd.pdf')
      expect(output).to include('Eintraege gesamt:            1')
    end

    it 'says plainly when no entry exists under that id' do
      record
      ENV['ORG'] = SecureRandom.uuid

      output = run_report

      expect(output).to include('kein Eintrag unter dieser Kennung')
      expect(output).to include('Keine Eintraege.')
    end

    # The start date belongs to the register, not to the selection. Recomputing
    # it per organisation would date the register to that organisation's first
    # deletion and hide everything the register genuinely cannot cover.
    it 'still reports the start date of the whole register' do
      old = record(organisation_id: SecureRandom.uuid, organisation_name: 'Alte GmbH')
      old.update_column(:created_at, Time.zone.local(2026, 8, 5, 12, 0))
      mine = SecureRandom.uuid
      younger = record(organisation_id: mine, organisation_name: 'Meine GmbH')
      younger.update_column(:created_at, Time.zone.local(2027, 1, 1, 12, 0))
      ENV['ORG'] = mine

      expect(run_report).to include('Verzeichnis gefuehrt seit:   2026-08-05')
    end
  end

  it 'writes nothing' do
    record

    expect { run_report }.not_to change(AttachmentDeletionRecord, :count)
  end
end
