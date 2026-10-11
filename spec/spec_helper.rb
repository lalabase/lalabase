# frozen_string_literal: true

require 'simplecov'
SimpleCov.start 'rails' do
  # Groups for a better overview in the report
  add_group 'Services',    'app/services'
  add_group 'Jobs',        'app/jobs'
  add_group 'Policies',    'app/policies'
  add_group 'Components',  'app/components'

  # Exclude irrelevant files
  add_filter '/spec/'
  add_filter '/config/'
  add_filter '/db/'
  add_filter '/vendor/'

  # Minimum coverage (optionally enable once the baseline is known)
  # minimum_coverage 70
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
  config.shared_context_metadata_behavior = :apply_to_host_groups
end
