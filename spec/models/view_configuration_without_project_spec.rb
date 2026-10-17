# frozen_string_literal: true

require 'rails_helper'

# The base view of "Alle Meetings" (meetings_uebersicht_vereinheitlichen_plan.md,
# PR 2): a view configuration without a project. Only the meetings list has a
# page without a project, so only view_type 'meetings' may go without one. The
# row of a project and the row of the organisation are separate, and there is
# at most one row without a project per user, organisation and view type: in
# the validation AND in the database, because Postgres counts NULLs as distinct
# and the unique index over (user_id, project_id, view_type) lets any number of
# them through.
RSpec.describe ViewConfiguration, 'without a project' do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def build_overview_config(view_type: 'meetings', in_organisation: organisation)
    described_class.new(user: user, organisation: in_organisation, project: nil, view_type: view_type)
  end

  describe 'validations' do
    it 'accepts a meetings view without a project' do
      expect(build_overview_config).to be_valid
    end

    %w[tickets notes documents].each do |view_type|
      it "refuses a #{view_type} view without a project" do
        config = build_overview_config(view_type: view_type)

        expect(config).not_to be_valid
        expect(config.errors[:project]).to be_present
      end
    end

    it 'refuses a second row without a project for the same user, organisation and view type' do
      build_overview_config.save!

      duplicate = build_overview_config
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:user_id]).to be_present
    end

    it 'allows the row without a project next to the row of a project' do
      described_class.create!(user: user, organisation: organisation, project: project, view_type: 'meetings')

      expect(build_overview_config).to be_valid
    end

    it 'allows a row without a project in each organisation' do
      build_overview_config.save!

      ActsAsTenant.with_tenant(other_organisation) do
        expect(build_overview_config(in_organisation: other_organisation)).to be_valid
      end
    end

    it 'still refuses a second row of the same project' do
      described_class.create!(user: user, organisation: organisation, project: project, view_type: 'meetings')

      duplicate = described_class.new(user: user, organisation: organisation, project: project, view_type: 'meetings')
      expect(duplicate).not_to be_valid
    end
  end

  describe 'the unique index' do
    it 'refuses a second row without a project even past the validation' do
      build_overview_config.save!

      expect { build_overview_config.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'takes one row without a project per organisation' do
      build_overview_config.save!

      ActsAsTenant.with_tenant(other_organisation) do
        expect { build_overview_config(in_organisation: other_organisation).save!(validate: false) }.not_to raise_error
      end
    end
  end

  describe '.for_user_organisation' do
    it 'starts with the columns "Alle Meetings" always showed, project and participants pinned' do
      config = described_class.for_user_organisation(user, organisation, 'meetings')

      expect(config).not_to be_persisted
      expect(config.project).to be_nil
      expect(config.organisation).to eq(organisation)
      expect(config.ordered_columns).to eq(%w[title project occurred_at duration_minutes participants])
      expect(config.pinned_column_keys).to eq(%w[project participants])
    end

    it 'returns the stored row' do
      stored = build_overview_config.tap(&:save!)

      expect(described_class.for_user_organisation(user, organisation, 'meetings')).to eq(stored)
    end

    it 'never returns the row of a project' do
      described_class.create!(user: user, organisation: organisation, project: project, view_type: 'meetings',
                              table_columns: %w[title creator])

      config = described_class.for_user_organisation(user, organisation, 'meetings')
      expect(config).not_to be_persisted
      expect(config.ordered_columns).to include('project')
    end

    it 'never returns the row of another organisation' do
      ActsAsTenant.with_tenant(other_organisation) { build_overview_config(in_organisation: other_organisation).save! }

      expect(described_class.for_user_organisation(user, organisation, 'meetings')).not_to be_persisted
    end
  end

  describe '.for_list' do
    it 'picks the row of the project when there is one, the organisation row otherwise' do
      with_project = described_class.for_list(user: user, organisation: organisation, project: project, view_type: 'meetings')
      without = described_class.for_list(user: user, organisation: organisation, project: nil, view_type: 'meetings')

      expect(with_project.project).to eq(project)
      expect(without.project).to be_nil
      expect(without.organisation).to eq(organisation)
    end
  end

  describe 'columns' do
    it 'offers the column "Projekt" only without a project' do
      without = described_class.available_columns_for(nil, 'meetings').pluck(:key)
      with_project = described_class.available_columns_for(project, 'meetings').pluck(:key)

      expect(without).to eq(with_project + %w[project])
      expect(with_project).not_to include('project')
      expect(described_class.available_columns_for(nil, 'meetings').find { |column| column[:key] == 'project' })
        .to include(label: 'Projekt')
    end

    it 'starts a project page without the column "Projekt"' do
      expect(described_class.default_columns_for(project, 'meetings')).to eq(%w[title occurred_at duration_minutes participants])
      expect(described_class.default_columns_for(nil, 'meetings')).to eq(%w[title project occurred_at duration_minutes participants])
    end

    it 'answers the ticket helpers without a project instead of raising' do
      expect(described_class.available_columns_for(nil, 'tickets').pluck(:key)).to include('number', 'title')
      expect(described_class.status_attribute_for(nil)).to be_nil
      expect(described_class.time_columns_visible_for?(nil, user)).to be false
      expect(build_overview_config.kanban_eligible_attributes).to be_empty
      expect(build_overview_config.available_header_columns.pluck(:key)).to include('assignees')
    end
  end
end
