# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake organisations:backfill_code_indexing`, the copy run behind step 4
#       of doc/projekt_chat_abbau_plan.md.
# Type: Rake task spec.
# Why:  The task runs BETWEEN two deploys, and both neighbours can overtake
#       it. That is why this spec holds the three properties the operator
#       relies on and that would otherwise only be promised: it copies in ONE
#       direction only, it does not touch an organisation that the operator
#       switched over after the deploy, and the dry run writes nothing.
#
#       The third one is the most expensive: the dry run is the only preview before
#       a run over all organisations.
RSpec.describe 'organisations:backfill_code_indexing' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('organisations:backfill_code_indexing')
  end

  before { Rake::Task['organisations:backfill_code_indexing'].reenable }

  after { ENV.delete('DRY_RUN') }

  def run_task
    Rake::Task['organisations:backfill_code_indexing'].invoke
  end

  # ⚠️ The old column is written with raw SQL because the models ignore it since
  # release 2 -- the same reason the task reads it that way. A fixture that could still
  # set it through the model would be testing a world the code does not live in.
  def organisation_with(old:, new:)
    organisation = create(:organisation, code_indexing_enabled: new)
    Organisation.connection.exec_update(
      'UPDATE organisations SET project_chat_enabled = $1 WHERE id = $2', nil,
      [ActiveRecord::Relation::QueryAttribute.new('project_chat_enabled', old,
                                                  ActiveRecord::Type::Boolean.new),
       ActiveRecord::Relation::QueryAttribute.new('id', organisation.id,
                                                  ActiveRecord::Type::String.new)]
    )
    organisation
  end

  it 'kopiert die alte Spalte in die neue' do
    org = organisation_with(old: true, new: false)

    expect { run_task }.to output(/1 Organisationen umgestellt/).to_stdout

    expect(org.reload.code_indexing_enabled).to be(true)
  end

  it 'laesst die alte Spalte stehen, Release 3 loescht sie' do
    org = organisation_with(old: true, new: false)

    expect { run_task }.to output(/umgestellt/).to_stdout

    expect(legacy_flag(org)).to be(true)
  end

  # ⚠️ The direction is the whole safety of this task. Since release 2 the admin
  # area only writes the NEW column; an accidental second run after that must not
  # turn an organisation switched on that way backwards to the old column,
  # and certainly not switch it off again.
  it 'kopiert NICHT rueckwaerts: neue an, alte aus, bleibt unangetastet' do
    org = organisation_with(old: false, new: true)

    expect { run_task }.to output(/1 bereits nur ueber die neue Spalte/).to_stdout

    expect(org.reload.code_indexing_enabled).to be(true)
    expect(legacy_flag(org)).to be(false)
  end

  it 'ist idempotent: ein zweiter Lauf stellt nichts mehr um' do
    organisation_with(old: true, new: false)
    capture_stdout { run_task }
    Rake::Task['organisations:backfill_code_indexing'].reenable

    expect { run_task }.to output(/0 Organisationen umgestellt/).to_stdout
  end

  it 'fasst eine Organisation ohne den alten Schalter nicht an' do
    org = organisation_with(old: false, new: false)

    capture_stdout { run_task }

    expect(org.reload.code_indexing_enabled).to be(false)
  end

  describe 'DRY_RUN' do
    before { ENV['DRY_RUN'] = '1' }

    it 'nennt die betroffenen Organisationen beim Namen und schreibt nichts' do
      org = organisation_with(old: true, new: false)
      org.update!(name: 'Muster Holzbau GmbH')

      expect { run_task }.to output(/DRY_RUN.*1 Organisationen waeren umgestellt.*Muster Holzbau GmbH/m).to_stdout

      expect(org.reload.code_indexing_enabled).to be(false)
      expect(legacy_flag(org)).to be(true) # the dry run does not touch the old one either
    end
  end

  # Read past ignored_columns, the same way the task does.
  def legacy_flag(organisation)
    Organisation.connection.select_value(
      "SELECT project_chat_enabled FROM organisations WHERE id = '#{organisation.id}'"
    )
  end

  def capture_stdout(&)
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end
end
