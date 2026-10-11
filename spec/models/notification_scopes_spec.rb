# frozen_string_literal: true

require 'rails_helper'

# Notification#this_week had no spec at all, which is how it carried the same
# date-range defect as Activity and UserActivity unnoticed: the range was bound with
# Date#end_of_week, a DATE, and Rails binds that as midnight, so the whole last day of
# the week fell outside.
#
#   ... Sun 23:59:59.999999 | Mon 00:00:00 ...
#        ^ last moment in     ^ first moment out
#
# Time is frozen on a Sunday, because a scope that is only wrong on the last day of the
# period is green on six days out of seven - which is exactly why the sibling spec in
# activity_spec.rb went red for the first time on 2026-09-06 at 00:11 UTC and not before.
RSpec.describe Notification, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:recipient) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }

  def notification_at(moment)
    create(:notification, recipient: recipient, organisation: organisation, created_at: moment)
  end

  describe '.this_week' do
    context 'on the last day of the week' do
      around { |example| travel_to(Time.zone.parse('2026-09-06 22:30:00')) { example.run } }

      it 'contains a notification created that very day' do
        expect(described_class.this_week).to include(notification_at(Time.current))
      end

      it 'contains the last moment of the week and excludes the first of the next' do
        last_moment = notification_at(Time.current.end_of_week)
        next_week = notification_at(Time.current.end_of_week + 1.second)

        expect(described_class.this_week).to include(last_moment)
        expect(described_class.this_week).not_to include(next_week)
      end

      it 'contains the first moment of the week and excludes the last of the previous' do
        first_moment = notification_at(Time.current.beginning_of_week)
        previous_week = notification_at(Time.current.beginning_of_week - 1.second)

        expect(described_class.this_week).to include(first_moment)
        expect(described_class.this_week).not_to include(previous_week)
      end
    end
  end
end
