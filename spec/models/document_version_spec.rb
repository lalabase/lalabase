# frozen_string_literal: true

# == Schema Information
#
# Table name: document_versions
#
#  id                       :uuid             not null, primary key
#  create_embeddings        :boolean          default(TRUE)
#  create_summary           :boolean          default(FALSE)
#  description              :text
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  generated_summary        :text             default("")
#  number                   :integer
#  plain_text_version       :text
#  plain_text_word_count    :integer
#  summary_creation_error   :text             default("")
#  summary_creation_flag    :boolean          default(FALSE)
#  title                    :string
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  document_id              :uuid             not null
#  organisation_id          :uuid             not null
#  user_id                  :uuid
#
# Indexes
#
#  index_document_versions_on_document_id      (document_id)
#  index_document_versions_on_organisation_id  (organisation_id)
#  index_document_versions_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
require 'rails_helper'

# Mutation-hardened spec for DocumentVersion (previously untested).
# Focus: required validations (title + file), migration defaults as a contract,
# dependent: :destroy on fragments, tenant isolation.
RSpec.describe DocumentVersion, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:document)     { create(:document, project: project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def attach_dummy(version)
    version.document_version_file.attach(
      io: StringIO.new('dummy'), filename: 'test.txt', content_type: 'text/plain'
    )
    version
  end

  describe 'associations' do
    it { is_expected.to belong_to(:document) }
    it { is_expected.to have_many(:fragments).dependent(:destroy) }
    # Uploader is optional: historic versions predate the column and stay NULL.
    it { is_expected.to belong_to(:user).optional }
  end

  describe 'validations' do
    it 'ist mit title + Datei valide' do
      v = build(:document_version, document: document, organisation: organisation)
      expect(v).to be_valid
    end

    it 'ist ungueltig ohne title' do
      v = build(:document_version, document: document, organisation: organisation, title: nil)
      expect(v).not_to be_valid
      expect(v.errors[:title]).to be_present
    end

    it 'ist ungueltig ohne angehaengte Datei' do
      v = DocumentVersion.new(title: 'Ohne Datei', document: document, organisation: organisation)
      expect(v).not_to be_valid
      expect(v.errors[:document_version_file]).to be_present
    end
  end

  describe 'Migration-Defaults (Vertrag — NICHT via Factory gesetzt)' do
    subject(:version) do
      # DELIBERATELY without create_embeddings/create_summary/flags -> DB defaults must take effect.
      v = DocumentVersion.new(title: 'Default-Check', document: document, organisation: organisation)
      attach_dummy(v)
      v.save!
      v.reload
    end

    it 'create_embeddings defaultet auf true' do
      expect(version.create_embeddings).to be(true)
    end

    it 'create_summary defaultet auf false' do
      expect(version.create_summary).to be(false)
    end

    it 'summary_creation_flag defaultet auf false' do
      expect(version.summary_creation_flag).to be(false)
    end

    it 'generated_summary + summary_creation_error defaulten auf Leerstring' do
      expect(version.generated_summary).to eq('')
      expect(version.summary_creation_error).to eq('')
    end
  end

  describe 'Cascade-Delete' do
    it 'deklariert dependent: :destroy auf fragments' do
      # Pure declaration check (fragment setup needs pgvector); mutation
      # (dependent removed) turns the shoulda matcher red.
      is_expected.to have_many(:fragments).dependent(:destroy)
    end
  end

  describe 'Tenant-Isolation (acts_as_tenant)' do
    it 'sieht Versionen eines anderen Tenants nicht im Default-Scope' do
      mine = create(:document_version, document: document, organisation: organisation)

      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        other_doc     = create(:document, project: other_project, organisation: other_org)
        create(:document_version, document: other_doc, organisation: other_org)
        expect(DocumentVersion.all).not_to include(mine)
      end

      expect(DocumentVersion.all).to include(mine)
    end
  end

  # v1, v2, ... per document (doc/dokumentansicht_plan.md, S1)
  describe 'the number' do
    let(:organisation) { create(:organisation) }
    let(:document) { ActsAsTenant.with_tenant(organisation) { create(:document, organisation: organisation) } }

    def version(number)
      ActsAsTenant.with_tenant(organisation) do
        build(:document_version, document: document, organisation: organisation, number: number)
      end
    end

    it 'is unique per document, and may be missing until the stock is numbered' do
      ActsAsTenant.with_tenant(organisation) { version(1).save! }
      expect(version(1)).not_to be_valid
      expect(version(2)).to be_valid
      expect(version(nil)).to be_valid
    end

    it 'is a positive integer' do
      expect(version(0)).not_to be_valid
      expect(version(-1)).not_to be_valid
      expect(version(1.5)).not_to be_valid
    end

    it 'labels itself as vN, or not at all' do
      expect(version(3).label).to eq('v3')
      expect(version(nil).label).to be_nil
    end
  end
end
