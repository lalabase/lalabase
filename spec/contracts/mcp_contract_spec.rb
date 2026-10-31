# frozen_string_literal: true

require 'rails_helper'
require_relative 'mcp_contract_recorder'

# Compares spec/fixtures/mcp_contract.json with what the server answers today
# (terminal client plan, S0 a). It never writes the file: a difference is either
# a change the client must learn about (regenerate, bump the MCP minor version,
# tell the client repository) or a mistake in this change.
RSpec.describe 'MCP contract file' do
  let(:file) { McpContract.read }

  it 'matches what the server answers today' do
    differences = McpContract.differences(file.fetch('contract'), McpContract::Recorder.new.call)

    expect(differences).to be_empty, <<~MESSAGE
      The MCP contract changed in #{differences.size} place(s):

        #{differences.first(25).join("\n  ")}

      If the change is intended: regenerate with `#{McpContract::REGENERATE}`, keep
      the MCP surface additive (Mcp::Dispatcher::SERVER_VERSION, minor bump) and
      update the copy in lalabase/lalabase-cli.
    MESSAGE
  end

  it 'names the core commit it was made from, outside the compared payload' do
    expect(file.keys).to eq(%w[header contract])
    expect(file.dig('header', 'core_commit')).to match(/\A\h{40}\z/)
    expect(file.dig('header', 'regenerate')).to eq(McpContract::REGENERATE)
  end

  # The commit names the base of the working tree, which during a PR does not
  # hold the change yet. The checksum names the payload itself, and catches a
  # hand edit that was never regenerated.
  it 'carries the checksum of the compared payload' do
    expect(file.dig('header', 'contract_sha256')).to eq(McpContract.checksum(file.fetch('contract')))
  end

  it 'records the version the server advertises' do
    version = file.dig('contract', 'mcp', 'initialize', 'response', 'body', 'result', 'serverInfo', 'version')
    expect(version).to eq(Mcp::Dispatcher::SERVER_VERSION)
  end

  # The file goes into another repository: it must not carry a credential.
  it 'carries no token' do
    expect(McpContract::FILE.read).not_to match(/lalab_pat_[A-Za-z0-9]{20,}/)
  end
end
