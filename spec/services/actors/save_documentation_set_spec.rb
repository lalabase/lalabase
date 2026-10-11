# frozen_string_literal: true

require 'rails_helper'

# What: Actors::SaveDocumentationSet — create/update contract + failure mapping.
# Type: Service (actor) spec.
# Why:  The actor is the write seam for connecting a doc set; a foreign repo or
#       a foreign-tenant id must map to a failure Result, not a raw exception.
RSpec.describe Actors::SaveDocumentationSet, type: :service do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:repo) { create(:project_repository, project: project, organisation: organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }

  describe 'create' do
    it 'creates a set from valid params' do
      result = described_class.call(
        project: project,
        params: { name: 'Handbuch', path_prefix: 'docs/', project_repository_id: repo.id },
        current_user: user
      )

      expect(result).to be_success
      expect(result.resource).to be_persisted
      expect(result.resource.name).to eq('Handbuch')
      expect(result.resource.path_prefix).to eq('docs/')
    end

    it 'maps a blank name to a diagnostic validation failure' do
      result = described_class.call(
        project: project, params: { name: '', project_repository_id: repo.id }, current_user: user
      )

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      expect(result.resource.errors[:name]).to be_present
    end

    it 'maps a repo/project mismatch to a validation failure' do
      other_repo = create(:project_repository, organisation: organisation)

      result = described_class.call(
        project: project,
        params: { name: 'X', project_repository_id: other_repo.id },
        current_user: user
      )

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
    end
  end

  describe 'update' do
    it 'updates an existing set' do
      set = create(:documentation_set, project: project, name: 'Alt')

      result = described_class.call(project: project, id: set.id, params: { name: 'Neu' }, current_user: user)

      expect(result).to be_success
      expect(set.reload.name).to eq('Neu')
    end

    it 'fails for a foreign-tenant id (no cross-tenant write)' do
      other_org = create(:organisation)
      foreign_set = ActsAsTenant.with_tenant(other_org) do
        create(:documentation_set, project: create(:project, organisation: other_org))
      end

      result = described_class.call(project: project, id: foreign_set.id, params: { name: 'x' }, current_user: user)

      expect(result).not_to be_success
      expect(foreign_set.reload.name).not_to eq('x')
    end
  end
end
