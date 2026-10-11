# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolders::Filters::VersionCountFilter, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  let(:smart_folder) do
    create(:smart_folder, organisation: organisation, user: user, project: project,
                          target_object_type: 'Document')
  end
  let(:rule_group) { create(:smart_folder_rule_group, smart_folder: smart_folder) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  after { ActsAsTenant.current_tenant = nil }

  def build_rule(operator:, value:)
    create(:smart_folder_rule,
           smart_folder_rule_group: rule_group,
           field: 'version_count', operator: operator, value: value.to_s)
  end

  def apply_filter(rule, query: Document.all)
    described_class.new(rule).apply(query, 'Document')
  end

  def result_ids(relation)
    relation.pluck(:id)
  end

  # -- Test data ------------------------------------------------------------

  # Prosopite.pause: the broadcast_updated callback in DocumentVersion triggers
  # an N+1 on active_storage_blobs — irrelevant for filter tests.
  let!(:doc_no_versions) do
    create(:document, project: project, organisation: organisation, creator: user)
  end

  let!(:doc_one_version) do
    Prosopite.pause do
      doc = create(:document, project: project, organisation: organisation, creator: user)
      create(:document_version, document: doc, organisation: organisation)
      doc
    end
  end

  let!(:doc_three_versions) do
    Prosopite.pause do
      doc = create(:document, project: project, organisation: organisation, creator: user)
      create_list(:document_version, 3, document: doc, organisation: organisation)
      doc
    end
  end

  # -- equals ---------------------------------------------------------------

  describe "operator 'equals'" do
    it 'finds documents with exactly the given version count' do
      rule = build_rule(operator: 'equals', value: 1)
      result = apply_filter(rule)

      expect(result_ids(result)).to contain_exactly(doc_one_version.id)
    end

    it 'finds documents with 0 versions' do
      rule = build_rule(operator: 'equals', value: 0)
      result = apply_filter(rule)

      expect(result_ids(result)).to contain_exactly(doc_no_versions.id)
    end

    it 'finds documents with 3 versions' do
      rule = build_rule(operator: 'equals', value: 3)
      result = apply_filter(rule)

      expect(result_ids(result)).to contain_exactly(doc_three_versions.id)
    end

    it 'returns empty when no document matches the count' do
      rule = build_rule(operator: 'equals', value: 99)
      result = apply_filter(rule)

      expect(result).to be_empty
    end
  end

  # -- not_equals -----------------------------------------------------------

  describe "operator 'not_equals'" do
    it 'excludes documents with the given version count' do
      rule = build_rule(operator: 'not_equals', value: 1)
      result = apply_filter(rule)

      expect(result_ids(result)).to contain_exactly(doc_no_versions.id, doc_three_versions.id)
    end

    it 'excludes documents with 0 versions (returns only docs WITH versions)' do
      rule = build_rule(operator: 'not_equals', value: 0)
      result = apply_filter(rule)

      expect(result_ids(result)).to contain_exactly(doc_one_version.id, doc_three_versions.id)
    end

    it 'returns all documents when no document matches the excluded count' do
      rule = build_rule(operator: 'not_equals', value: 99)
      result = apply_filter(rule)

      expect(result_ids(result)).to contain_exactly(
        doc_no_versions.id, doc_one_version.id, doc_three_versions.id
      )
    end
  end

  # -- greater_than --------------------------------------------------------

  describe "operator 'greater_than'" do
    it 'finds documents with more versions than the threshold' do
      rule = build_rule(operator: 'greater_than', value: 1)
      result = apply_filter(rule)

      expect(result_ids(result)).to contain_exactly(doc_three_versions.id)
    end

    it 'excludes documents with 0 versions for threshold 0' do
      rule = build_rule(operator: 'greater_than', value: 0)
      result = apply_filter(rule)

      expect(result_ids(result)).to contain_exactly(doc_one_version.id, doc_three_versions.id)
    end

    it 'returns empty when no document exceeds the threshold' do
      rule = build_rule(operator: 'greater_than', value: 100)
      result = apply_filter(rule)

      expect(result).to be_empty
    end
  end

  # -- less_than ------------------------------------------------------------

  describe "operator 'less_than'" do
    it 'finds documents with fewer versions than the threshold' do
      rule = build_rule(operator: 'less_than', value: 3)
      result = apply_filter(rule)

      expect(result_ids(result)).to contain_exactly(doc_no_versions.id, doc_one_version.id)
    end

    it 'includes documents with 0 versions' do
      rule = build_rule(operator: 'less_than', value: 1)
      result = apply_filter(rule)

      expect(result_ids(result)).to contain_exactly(doc_no_versions.id)
    end

    it 'returns empty when no document is below the threshold' do
      rule = build_rule(operator: 'less_than', value: 0)
      result = apply_filter(rule)

      expect(result).to be_empty
    end
  end

  # -- Edge Cases -----------------------------------------------------------

  describe 'non-Document query' do
    it 'returns query unchanged when model is not Document' do
      rule = build_rule(operator: 'equals', value: 1)
      ticket_query = Ticket.all
      result = described_class.new(rule).apply(ticket_query, 'Ticket')

      expect(result.to_sql).to eq(ticket_query.to_sql)
    end
  end

  describe 'invalid value' do
    it 'returns empty relation for non-numeric string' do
      rule = build_rule(operator: 'equals', value: 1)
      rule.update_column(:value, 'abc')
      rule.reload

      expect(Rails.logger).to receive(:error).with(/Invalid number format/)
      result = apply_filter(rule)

      expect(result).to be_empty
      expect(result).to be_a(ActiveRecord::Relation)
    end

    it 'returns empty relation for nil value' do
      rule = build_rule(operator: 'equals', value: 1)
      rule.update_column(:value, nil)
      rule.reload

      expect(Rails.logger).to receive(:error).with(/Invalid number format/)
      result = apply_filter(rule)

      expect(result).to be_empty
    end

    it 'returns empty relation for empty string' do
      rule = build_rule(operator: 'equals', value: 1)
      rule.update_column(:value, '')
      rule.reload

      expect(Rails.logger).to receive(:error).with(/Invalid number format/)
      result = apply_filter(rule)

      expect(result).to be_empty
    end

    it 'returns empty relation for float string' do
      rule = build_rule(operator: 'equals', value: 1)
      rule.update_column(:value, '2.5')
      rule.reload

      expect(Rails.logger).to receive(:error).with(/Invalid number format/)
      result = apply_filter(rule)

      expect(result).to be_empty
    end
  end

  describe 'unsupported operator' do
    it 'returns query unchanged and logs warning' do
      rule = build_rule(operator: 'equals', value: 1)
      rule.update_column(:operator, 'contains')
      rule.reload

      expect(Rails.logger).to receive(:warn).with(/Unsupported version count operator 'contains'/)

      query = Document.all
      result = apply_filter(rule)

      expect(result.to_sql).to eq(query.to_sql)
    end
  end

  describe 'empty dataset' do
    before { Document.delete_all }

    it 'returns empty relation without errors' do
      rule = build_rule(operator: 'equals', value: 0)
      result = apply_filter(rule)

      expect(result).to be_empty
      expect(result).to be_a(ActiveRecord::Relation)
    end
  end

  describe 'boundary: all documents have same version count' do
    before do
      Prosopite.pause do
        # Bring all docs to 2 versions
        doc_no_versions.document_versions.delete_all
        create_list(:document_version, 2, document: doc_no_versions, organisation: organisation)

        doc_one_version.document_versions.delete_all
        create_list(:document_version, 2, document: doc_one_version, organisation: organisation)

        doc_three_versions.document_versions.delete_all
        create_list(:document_version, 2, document: doc_three_versions, organisation: organisation)
      end
    end

    it 'equals returns all documents' do
      rule = build_rule(operator: 'equals', value: 2)
      result = apply_filter(rule)

      expect(result_ids(result).length).to eq(3)
    end

    it 'not_equals returns no documents' do
      rule = build_rule(operator: 'not_equals', value: 2)
      result = apply_filter(rule)

      expect(result_ids(result)).to be_empty
    end

    it 'greater_than returns no documents' do
      rule = build_rule(operator: 'greater_than', value: 2)
      result = apply_filter(rule)

      expect(result_ids(result)).to be_empty
    end

    it 'less_than returns no documents' do
      rule = build_rule(operator: 'less_than', value: 2)
      result = apply_filter(rule)

      expect(result_ids(result)).to be_empty
    end
  end

  describe 'negative value' do
    it 'equals with negative value returns empty (version count is always >= 0)' do
      rule = build_rule(operator: 'equals', value: -1)
      result = apply_filter(rule)

      expect(result).to be_empty
    end

    it 'less_than with negative value returns empty' do
      rule = build_rule(operator: 'less_than', value: -1)
      result = apply_filter(rule)

      expect(result).to be_empty
    end

    it 'greater_than with negative value returns all documents' do
      rule = build_rule(operator: 'greater_than', value: -1)
      result = apply_filter(rule)

      expect(result_ids(result).length).to eq(3)
    end
  end

  describe 'chaining with existing scopes' do
    it 'respects pre-existing WHERE conditions' do
      rule = build_rule(operator: 'greater_than', value: 0)
      scoped_query = Document.where(id: doc_one_version.id)
      result = apply_filter(rule, query: scoped_query)

      expect(result_ids(result)).to contain_exactly(doc_one_version.id)
    end

    it 'does not produce duplicates when document has many versions' do
      rule = build_rule(operator: 'greater_than', value: 0)
      ids = result_ids(apply_filter(rule))

      expect(ids.uniq.length).to eq(ids.length)
    end
  end
end
