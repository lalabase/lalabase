# frozen_string_literal: true

require 'rails_helper'
require 'yaml'

# What: the CI job that runs the bin/lala tests exists, runs the command that
#   finds them, and there are tests for it to find.
# Why: ci_guard_list_spec.rb reads only the rspec step, so nothing else noticed if
#   the `lala` job went missing or its discover pattern stopped matching a file.
#   unittest finding no test is green on older Pythons. bin/lala prints text other
#   members wrote into a terminal and into a model's context; its tests are the
#   only thing that holds clean(), the fence and the error paths
#   (spec/python/lala_test.py, PR #961).
RSpec.describe 'CI runs the bin/lala tests' do
  let(:workflow) { YAML.safe_load_file(Rails.root.join('.github/workflows/guards.yml'), aliases: true) }
  let(:command) { "python3 -m unittest discover -s spec/python -p '*_test.py'" }

  let(:job) { workflow.fetch('jobs').fetch('lala') }
  let(:test_step) { job.fetch('steps').find { |step| step['run'].to_s.start_with?(command) } }

  it 'has a job that runs the bin/lala tests' do
    expect(test_step).to be_present
  end

  # A job or step that is switched off or allowed to fail is green while it guards nothing.
  it 'neither skips the job nor lets it fail quietly' do
    [job, test_step].each do |node|
      expect(node).not_to include('if', 'continue-on-error')
    end
  end

  it 'has tests for that command to find' do
    expect(Rails.root.glob('spec/python/*_test.py')).not_to be_empty
  end
end
