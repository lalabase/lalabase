# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake product_knowledge:sync`, the manual repair of the table.
# Type: Rake task spec; the service specs prove what a sync does, this holds the wiring: the
#   task always forces (rewrites every row, ignores the release order), prints what it did,
#   and says so when nothing was written.
RSpec.describe 'product_knowledge:sync' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('product_knowledge:sync')
  end

  before { Rake::Task['product_knowledge:sync'].reenable }

  def run_task
    output = StringIO.new
    original = $stdout
    $stdout = output
    Rake::Task['product_knowledge:sync'].invoke
    output.string
  ensure
    $stdout = original
    Rake::Task['product_knowledge:sync'].reenable
  end

  it 'forces and prints what the sync did' do
    allow(ProductKnowledge::EnsureFresh).to receive(:call)
      .and_return(ProductKnowledge::Sync::Result.new(written: 3, deleted: 1))

    output = run_task

    expect(ProductKnowledge::EnsureFresh).to have_received(:call).with(force: true)
    expect(output).to include('3 written, 1 deleted')
  end

  it 'says so when nothing was written' do
    allow(ProductKnowledge::EnsureFresh).to receive(:call).and_return(nil)

    expect(run_task).to include('nothing written')
  end

  it 'fills the table from the real help and rewrites every row on the next run' do
    first = run_task
    count = ProductKnowledgeEntry.count

    expect(count).to be_positive
    expect(first).to include("#{count} written, 0 deleted")
    expect(run_task).to include("#{count} written, 0 deleted, #{count} entries")
  end
end
