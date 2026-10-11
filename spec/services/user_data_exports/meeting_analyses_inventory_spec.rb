# frozen_string_literal: true

require 'rails_helper'

# Slice 7a inventory principle (plan §5 / D12, like created_meetings): the personal
# data export lists the user's OWN analyses as metadata only — prompt title, date,
# meeting — never the analysis `content` or the prompt snapshot (org-owned, possibly
# third-party PII). This guards against someone widening the source later.
RSpec.describe UserDataExports::Registry do
  it 'exports meeting analyses as inventory only (no content, no snapshot)' do
    source = described_class::SOURCES.find { |s| s.key == :meeting_analyses }

    expect(source).to be_present
    expect(source.exported_keys).to include('prompt_title')
    expect(source.exported_keys).not_to include('content')
    expect(source.exported_keys).not_to include('prompt_snapshot')
  end
end
