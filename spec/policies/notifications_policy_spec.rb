# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NotificationsPolicy, :ci_guard, type: :policy do
  let(:user) { create(:user) }

  describe 'mit eingeloggtem User' do
    subject { described_class.new(user, :notifications) }

    %i[
      mark_all_read?
      archive_all?
      preferences?
      update_preferences?
      ticket_exceptions?
      remove_ticket_exception?
      stats?
    ].each do |action|
      it "erlaubt #{action}" do
        expect(subject.public_send(action)).to be true
      end
    end
  end

  describe 'ohne User (nil)' do
    it 'wirft Pundit::NotAuthorizedError' do
      expect { described_class.new(nil, :notifications) }
        .to raise_error(Pundit::NotAuthorizedError, 'must be logged in')
    end
  end
end
