# frozen_string_literal: true

require 'rails_helper'

# What: viewer_display_time, a timestamp in the viewer's own format.
# Type: helper spec.
# Why: the version row is rendered twice, once for a request and once from a
#   job (DocumentVersion#broadcast_updated), where there is no viewer and
#   Devise's current_user raises. The first must honour the reader's format,
#   the second must not take the write down with it.
RSpec.describe ApplicationHelper, type: :helper do
  describe '#viewer_display_time' do
    let(:stamp) { Time.zone.local(2026, 6, 28, 14, 5) }

    it "writes the viewer's format" do
      user = build_stubbed(:user)
      allow(user).to receive(:date_strftime_format).and_return('%Y/%m/%d %H|%M')
      helper.define_singleton_method(:current_user) { user }

      expect(helper.viewer_display_time(stamp)).to eq('2026/06/28 14|05')
    end

    it 'falls back to the relative form when there is no viewer to ask' do
      helper.define_singleton_method(:current_user) { raise 'no warden' }

      expect(helper.viewer_display_time(stamp)).to eq(I18n.t('views.common.relative_time_ago', time: helper.time_ago_in_words(stamp)))
    end
  end
end
