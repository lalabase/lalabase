# frozen_string_literal: true

namespace :mcp do
  desc 'Regenerate spec/fixtures/mcp_contract.json from real answers (test database, rolled back)'
  task contract: :environment do
    # The recorder builds its data with factories and rolls it back afterwards.
    # Against a development or production database it would still write rows
    # with fixed ids before the rollback, and the factories are not loaded there.
    abort 'Run it against the test database: RAILS_ENV=test bin/rails mcp:contract' unless Rails.env.test?

    require Rails.root.join('spec/contracts/mcp_contract_recorder').to_s

    contract = McpContract.record_isolated
    McpContract.write(contract)
    header = McpContract.header(contract)
    puts "#{McpContract::FILE.relative_path_from(Rails.root)} written " \
         "(core #{header['core_commit'][0, 9]}#{'+dirty' if header['core_dirty']}, sha256 #{header['contract_sha256'][0, 12]})"
  end
end
