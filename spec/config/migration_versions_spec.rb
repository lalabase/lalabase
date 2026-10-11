# frozen_string_literal: true

# What: db/migrate — duplicate version prefix guard.
# Type: Config spec.
# Why:  Two migrations sharing a timestamp make Rails raise
#       ActiveRecord::DuplicateMigrationVersionError while LOADING, so the whole
#       suite dies before a single example runs — and the next
#       `cap production deploy` dies the same way in db:migrate.
#
#       Not hypothetical: on 2026-08-05, #475 and #478 each carried
#       20260805180000. Both were green on their own branch, because the
#       collision exists only in the COMBINATION. Any check that sees the
#       combined state catches it, and there are two such states: the PR merge
#       ref (so the second PR would have been red before merging) and main
#       itself. This guard runs on both (fixed by #482).
#
# NOTE — this file deliberately does NOT require rails_helper, and that is the
#       whole point. Booting Rails is exactly what explodes when the duplicate
#       exists, so a guard that boots Rails first can never report it: the first
#       draft of this spec was green in the healthy case and produced "0 examples,
#       1 error occurred outside of examples" in the case it was written for.
#       Plain Ruby over the directory, no Rails, no database.
#
#       For the same reason it runs as its OWN CI step, before the schema load
#       and the curated guard list — both of which boot Rails.
RSpec.describe 'db/migrate' do
  let(:repo_root) { File.expand_path('../..', __dir__) }
  let(:filenames) { Dir.glob(File.join(repo_root, 'db/migrate/*.rb')).map { |path| File.basename(path) } }
  let(:versions) { filenames.filter_map { |name| name[/\A\d+/] } }

  it 'finds migrations at all' do
    expect(filenames).not_to be_empty, 'no migrations found — is the path still right?'
  end

  it 'gives every migration a version' do
    unnumbered = filenames.grep_v(/\A\d+_/)

    expect(unnumbered).to be_empty, "not prefixed with a version: #{unnumbered.join(', ')}"
  end

  it 'uses every version only once' do
    duplicates = versions.tally.select { |_, count| count > 1 }.keys

    expect(duplicates).to be_empty,
                          "duplicate migration version(s): #{duplicates.join(', ')} — " \
                          'renumber the one that has NOT run on production yet ' \
                          '(ask schema_migrations before deciding, do not guess)'
  end

  # Equality, not ">=", and the name says so: if someone withdraws a migration,
  # deletes the file and leaves schema.rb alone, the schema records a state no
  # migration produces any more. ">=" would wave exactly that through, so do not
  # "relax" this to be >= versions.max.
  # The dedicated CI step IS the guard. Folded into the curated list, this file
  # would boot Rails with everything else and go silent in exactly the case it
  # exists for -- which is how the first draft was written. That made the
  # placement a rule enforced by two comments; this turns it into a mechanism.
  it 'runs as its own CI step, before anything boots Rails' do
    workflow = File.read(File.join(repo_root, '.github/workflows/guards.yml'))
    mentions = workflow.scan('spec/config/migration_versions_spec.rb').size
    guard_at = workflow.index('spec/config/migration_versions_spec.rb')
    schema_at = workflow.index('db:schema:load')

    expect(guard_at).to be_truthy, 'guards.yml no longer runs this spec at all'
    expect(mentions).to eq(1), 'listed more than once -- a second mention means it also boots with the curated list'
    expect(guard_at).to be < schema_at
  end

  it 'has a schema.rb generated from the newest migration' do
    schema = File.read(File.join(repo_root, 'db/schema.rb'))
    schema_version = schema[/define\(version:\s*([\d_]+)\)/, 1].to_s.delete('_')

    expect(schema_version).to eq(versions.max)
  end
end
