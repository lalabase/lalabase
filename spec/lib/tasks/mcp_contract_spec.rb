# frozen_string_literal: true

require 'rails_helper'
require 'rake'
require Rails.root.join('spec/contracts/mcp_contract_recorder').to_s

# What: `bin/rails mcp:contract` and McpContract.record_isolated, the path that
#       WRITES the contract file (the contract spec only compares).
# Why:  The recorder creates rows with fixed ids. Committed by mistake they would
#       stay in the test database and the next run would fail on its own ids; run
#       against another database they would land there. The contract spec cannot
#       see either: it calls the recorder directly.
RSpec.describe 'mcp:contract' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('mcp:contract')
  end

  before { Rake::Task['mcp:contract'].reenable }

  let(:fixed_id) { McpContract::Recorder::IDS.fetch(:organisation) }

  def fixed_organisation_exists?
    ActsAsTenant.without_tenant { Organisation.exists?(id: fixed_id) }
  end

  describe 'McpContract.record_isolated' do
    it 'leaves no row of its synthetic world behind' do
      contract = McpContract.record_isolated

      expect(contract.dig('mcp', 'initialize', 'response', 'status')).to eq(200)
      expect(fixed_organisation_exists?).to be(false)
      expect(ActsAsTenant.without_tenant { User.exists?(email: 'anna@example.com') }).to be(false)
    end

    it 'rolls back a run that fails halfway' do
      recorder = instance_double(McpContract::Recorder)
      allow(recorder).to receive(:call) do
        create(:organisation, id: fixed_id)
        raise 'recorder failed'
      end
      allow(McpContract::Recorder).to receive(:new).and_return(recorder)

      expect { McpContract.record_isolated }.to raise_error('recorder failed')
      expect(fixed_organisation_exists?).to be(false)
    end
  end

  describe 'the task' do
    it 'records through the isolated path and writes the file' do
      allow(McpContract).to receive_messages(record_isolated: { 'mcp' => {} }, write: nil)

      expect { Rake::Task['mcp:contract'].invoke }.to output(/mcp_contract\.json written/).to_stdout
      expect(McpContract).to have_received(:record_isolated)
      expect(McpContract).to have_received(:write).with({ 'mcp' => {} })
    end

    it 'refuses outside the test environment before it records or writes anything' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('development'))
      allow(McpContract).to receive(:record_isolated)
      allow(McpContract).to receive(:write)

      expect { Rake::Task['mcp:contract'].invoke }
        .to raise_error(SystemExit).and output(/RAILS_ENV=test/).to_stderr
      expect(McpContract).not_to have_received(:record_isolated)
      expect(McpContract).not_to have_received(:write)
    end
  end
end
