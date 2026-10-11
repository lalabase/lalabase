# frozen_string_literal: true

require 'rails_helper'
require 'yaml'

RSpec.describe 'Mobile browser CI configuration' do
  let(:workflow) { YAML.load_file(Rails.root.join('.github/workflows/guards.yml')) }
  let(:steps) { workflow.fetch('jobs').fetch('guards').fetch('steps') }

  it 'uploads both Rails and Capybara failure screenshots' do
    upload = steps.find { |step| step['uses']&.start_with?('actions/upload-artifact@') }
    expect(upload.fetch('if')).to eq('failure()')
    expect(upload.fetch('with').fetch('path').lines.map(&:strip)).to include('tmp/screenshots/', 'tmp/capybara/')
  end

  it 'does not expose the job environment to npm lifecycle scripts' do
    install = steps.find { |step| step['run']&.include?('npm ci') }.fetch('run')
    expect(install).to match(/npm ci\s+--ignore-scripts\b/)
    expect(install).to include('npm run copy:fonts')
  end
end
