# frozen_string_literal: true

require 'rails_helper'

# The two booked-time columns are the only ones whose availability depends on the
# USER rather than on the project's configuration. What is pinned here is that
# gate: a user who may see none of a project's time is not offered a column that
# could only ever render a dash, and a caller that cannot name a user does not
# get one either.
RSpec.describe ViewConfiguration, 'time columns' do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin) { create(:user) }
  let(:member) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: admin, organisation: organisation,
                        role: create(:admin_role, organisation: organisation))
    create(:membership, user: member, organisation: organisation)
  end

  after { ActsAsTenant.current_tenant = nil }

  def column_keys(user)
    described_class.available_columns_for(project, 'tickets', user: user).pluck(:key)
  end

  describe 'a user who may see the project\'s booked time' do
    it 'is offered every column of TIME_COLUMN_KEYS (tier :all)' do
      expect(column_keys(admin)).to include(*described_class::TIME_COLUMN_KEYS)
    end

    it 'is offered them on tier :own too, where the numbers cover only their own hours' do
      create(:time_session_permission, user: member, project: project, can_view_own: true, can_view_all: false)

      expect(TimeSessions::ViewingScope.call(user: member, project: project).tier).to eq(:own)
      expect(column_keys(member)).to include(*described_class::TIME_COLUMN_KEYS)
    end

    it 'gives each of them a label in both locales' do
      described_class::TIME_COLUMN_KEYS.each do |key|
        %i[de en].each do |locale|
          label = I18n.t("models.view_configuration.columns.#{key}", locale: locale, fallback: false)
          expect(label).to be_present, "missing #{locale} label for #{key}"
        end
      end
    end
  end

  describe 'a user who may see none of it' do
    # Fail-closed, the same bar as TimeSessions::ViewingScope: no persisted
    # permission row is :none, not the model's can_view_own default.
    it 'is offered neither column' do
      expect(TimeSessions::ViewingScope.call(user: member, project: project).tier).to eq(:none)
      expect(column_keys(member)).not_to include(*described_class::TIME_COLUMN_KEYS)
    end

    it 'keeps every other column it had' do
      expect(column_keys(member)).to include('number', 'title', 'assignees', 'tags', 'created_at', 'updated_at')
    end

    it 'is offered neither even with an explicit no-access permission row' do
      create(:time_session_permission, :no_access, user: member, project: project)

      expect(column_keys(member)).not_to include(*described_class::TIME_COLUMN_KEYS)
    end
  end

  describe 'a caller that names no user' do
    it 'gets no time columns, because it cannot be told what that user may see' do
      expect(described_class.available_columns_for(project, 'tickets').pluck(:key))
        .not_to include(*described_class::TIME_COLUMN_KEYS)
    end
  end

  describe 'the other view types' do
    %w[notes documents].each do |view_type|
      it "never offers them for #{view_type}, which has no booked time" do
        keys = described_class.available_columns_for(project, view_type, user: admin).pluck(:key)

        expect(keys).not_to include(*described_class::TIME_COLUMN_KEYS)
      end
    end
  end

  describe 'the instance method' do
    let(:config) { described_class.for_user_project(admin, project, 'tickets') }

    it 'reads the columns for its OWN user, not for whoever asks' do
      expect(config.available_columns.pluck(:key)).to include(*described_class::TIME_COLUMN_KEYS)
      expect(described_class.for_user_project(member, project, 'tickets').available_columns.pluck(:key))
        .not_to include(*described_class::TIME_COLUMN_KEYS)
    end

    it 'resolves the tier once, however often a render asks' do
      config.available_columns

      expect(TimeSessions::ViewingScope).not_to receive(:call)
      3.times { config.available_columns }
    end
  end
end
