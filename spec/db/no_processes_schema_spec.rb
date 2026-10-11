# frozen_string_literal: true

require 'rails_helper'

# What: the schema after Prozesse left (step 2 of 2, after #972).
# Why:  Slice 1a of Prozesse left main before the core went public; step 1
#       removed the code and parked the column in ignored_columns. Here the
#       tables and the column are gone, and nothing parks them any more: a
#       leftover ignored_columns entry would hide a column that a later
#       feature of the same name adds.
RSpec.describe 'Schema without Prozesse' do
  let(:connection) { ActiveRecord::Base.connection }

  it 'has no Prozesse tables and no processes_access column' do
    expect(connection.table_exists?(:business_processes)).to be(false)
    expect(connection.table_exists?(:process_steps)).to be(false)
    expect(connection.column_exists?(:project_permissions, :processes_access)).to be(false)
  end

  it 'parks no column any more' do
    expect(ProjectPermission.ignored_columns).not_to include('processes_access')
    expect(Admin::ProjectPermission.ignored_columns).not_to include('processes_access')
  end
end
