# frozen_string_literal: true

require 'rails_helper'
require 'yaml'

# What: every spec file the CI guard job names actually exists.
# Why: the list in .github/workflows/guards.yml is maintained by hand. Delete a
#   spec and the job does not skip it -- rspec fails to LOAD it and reports
#   "0 examples, 0 failures, 1 error occurred outside of examples", which reads
#   like an infrastructure hiccup rather than "your branch deleted a file the
#   list still names". Measured on 20.09.2026: the founder request spec left the
#   repo, the line stayed, and the job went red after every other job was green.
#
#   Running the list locally does not catch it either, because the obvious way
#   to run it is to extract the paths and pipe the existing ones to rspec.
module CiGuardList
  WORKFLOW = '.github/workflows/guards.yml'

  # The paths handed to the one step that runs rspec. Other steps legitimately
  # name spec/javascript/*.test.js, which node runs, not rspec.
  def self.rspec_paths(workflow = YAML.safe_load_file(Rails.root.join(WORKFLOW), aliases: true))
    steps = workflow.fetch('jobs').values.flat_map { |job| job['steps'] || [] }
    steps.filter_map { |step| step['run'] }
         .select { |run| run.include?('bundle exec rspec') }
         .flat_map { |run| run.scan(%r{spec/[A-Za-z0-9_/.-]+}) }
         .uniq
  end

  # A spec file is covered when the list names it or a directory above it. rspec
  # takes a directory with or without the trailing slash.
  def self.covered?(file, entries)
    entries.any? do |entry|
      Rails.root.join(entry).directory? ? file.start_with?("#{entry.chomp('/')}/") : file == entry
    end
  end

  # Spec files that declare they must run in CI: tagged :ci_guard (or ci_guard: true)
  # on a describe line. The file says so itself, so no second list has to be kept.
  # Only describe calls count, so a spec that merely mentions the tag is not tagged.
  # A call wrapped over several lines counts too: each line ending in "," or "("
  # carries its arguments on to the next one. The tag must be an argument, right
  # after "," or "(", so a title that mentions it does not count.
  TAG = /^\s*(?:RSpec\.)?describe\b(?:[^\n]*[,(][ \t]*\n)*[^\n]*?[,(]\s*(?::ci_guard\b|ci_guard: true\b)/

  def self.tagged_files
    Dir[Rails.root.join('spec/**/*_spec.rb')].filter_map do |path|
      Pathname(path).relative_path_from(Rails.root).to_s if File.read(path).match?(TAG)
    end.sort
  end
end

RSpec.describe 'The CI guard list', type: :model do
  it 'names only paths that exist' do
    paths = CiGuardList.rspec_paths
    expect(paths).not_to be_empty, "found no rspec invocation in #{CiGuardList::WORKFLOW}"

    missing = paths.reject { |path| File.exist?(Rails.root.join(path)) }

    expect(missing).to be_empty,
                       "#{CiGuardList::WORKFLOW} names files that are not in the repo:\n" \
                       "#{missing.join("\n")}\n\n" \
                       'rspec cannot load them, so the job reports an error outside of examples ' \
                       'and every example in the list goes unrun. Deleting a spec means deleting ' \
                       'its line here.'
  end

  # What: every spec tagged :ci_guard runs in the guard job.
  # Why: the list only proves that what it names exists. A deleted line went
  #   unnoticed, and security regression specs (#895, #896) ran nowhere. The tag
  #   sits in the spec, so removing a line from the list turns this red.
  it 'runs every spec tagged :ci_guard' do
    tagged = CiGuardList.tagged_files
    # Pinned so a broken scan cannot pass by finding nothing
    expect(tagged).to include('spec/requests/organisations/attribute_option_color_xss_spec.rb',
                              'spec/policies/post_policy_spec.rb')

    entries = CiGuardList.rspec_paths
    unlisted = tagged.reject { |file| CiGuardList.covered?(file, entries) }

    expect(unlisted).to be_empty,
                        "these specs are tagged :ci_guard but #{CiGuardList::WORKFLOW} does not run them:\n" \
                        "#{unlisted.join("\n")}\n\n" \
                        'Add each path (or a directory above it) to the rspec step of the guards job.'
  end

  describe 'what counts as listed, tagged and covered' do
    # A path named by any other step (node, an artifact upload) is not run by
    # rspec, so it must not count as covering a tagged spec.
    it 'reads paths only from steps that run rspec, each once' do
      workflow = { 'jobs' => {
        'guards' => { 'steps' => [
          { 'run' => "bundle exec rspec\nspec/architecture/\nspec/models/a_spec.rb\nspec/models/a_spec.rb" },
          { 'run' => 'npm test spec/javascript/x.test.js' },
          { 'with' => { 'path' => 'spec/policies/' } },
          { 'name' => 'no run key' }
        ] },
        'lint' => { 'runs-on' => 'ubuntu-latest' }
      } }

      expect(CiGuardList.rspec_paths(workflow)).to eq(%w[spec/architecture/ spec/models/a_spec.rb])
    end

    it 'counts the tag only on a describe line' do
      expect("RSpec.describe Foo, :ci_guard, type: :model do\n").to match(CiGuardList::TAG)
      expect("RSpec.describe Foo, ci_guard: true do\n").to match(CiGuardList::TAG)
      expect("  describe 'bar', :ci_guard do\n").to match(CiGuardList::TAG)
      expect("RSpec.describe Foo,\n               :ci_guard, type: :request do\n").to match(CiGuardList::TAG)
      expect("RSpec.describe(\n  Foo, :ci_guard\n) do\n").to match(CiGuardList::TAG)
      expect("RSpec.describe Foo do\n  it 'mentions :ci_guard' do\n").not_to match(CiGuardList::TAG)
      expect("  it 'calls describe', :ci_guard do\n").not_to match(CiGuardList::TAG)
      expect("RSpec.describe Foo, type: :model do\n  it 'x',\n     :ci_guard do\n").not_to match(CiGuardList::TAG)
      expect("RSpec.describe Foo, :ci_guard_other do\n").not_to match(CiGuardList::TAG)
      expect("RSpec.describe 'shows :ci_guard badge' do\n").not_to match(CiGuardList::TAG)
      expect("RSpec.describe Foo, 'with ci_guard: true set' do\n").not_to match(CiGuardList::TAG)
    end

    it 'covers a file through its own entry or a directory above it, nothing else' do
      file = 'spec/policies/post_policy_spec.rb'

      expect(CiGuardList.covered?(file, [file])).to be(true)
      expect(CiGuardList.covered?(file, ['spec/policies/'])).to be(true)
      expect(CiGuardList.covered?(file, ['spec/policies'])).to be(true)
      expect(CiGuardList.covered?(file, ['spec/pol'])).to be(false)
      expect(CiGuardList.covered?('spec/policies_old/post_policy_spec.rb', ['spec/policies'])).to be(false)
      expect(CiGuardList.covered?(file, ['spec/architecture/'])).to be(false)
      expect(CiGuardList.covered?(file, ['spec/policies/post_policy_privacy_spec.rb'])).to be(false)
    end
  end

  # A .js file handed to rspec raises SyntaxError while loading and takes the
  # whole run with it, the same failure shape as a missing file.
  it 'hands rspec no JavaScript' do
    javascript = CiGuardList.rspec_paths.grep(/\.js$/)

    expect(javascript).to be_empty,
                          "rspec cannot load JavaScript:\n#{javascript.join("\n")}\n\n" \
                          'The javascript job runs those with node.'
  end
end
