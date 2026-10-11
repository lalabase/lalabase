# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Browser database cleanup', type: :system do
  around do |example|
    @cleanup_events = []
    example.run

    expect(@cleanup_events).to include(:browser_drained, :database_cleaning)
    expect(@cleanup_events.index(:browser_drained)).to be < @cleanup_events.index(:database_cleaning)
  end

  before do
    allow(Capybara).to receive(:reset_sessions!).and_wrap_original do |reset, *args|
      reset.call(*args)
      @cleanup_events << :browser_drained if @record_cleanup
    end
    allow(DatabaseCleaner).to receive(:clean).and_wrap_original do |clean, *args|
      @cleanup_events << :database_cleaning if @record_cleanup
      clean.call(*args)
    end
  end

  it 'drains browser requests before deleting the records they can still read' do
    visit new_user_session_path
    expect(page).to have_css('input[type="password"]')
    @record_cleanup = true
  end
end
