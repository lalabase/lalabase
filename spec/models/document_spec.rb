# frozen_string_literal: true

require 'rails_helper'

# Mutation-hardened spec for the Document model (previously untested).
# Focus: break at the decision points — belongs_to requirement, DB NOT NULL
# (defense in depth), tenant isolation, dependent: :destroy, the title/description
# delegation to current_version (incl. nil guard), and the create-tracking callback.
RSpec.describe Document, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # Helper: document with current version (title/description live on the version)
  def document_with_version(title: 'Titel', description: 'Beschreibung')
    doc     = create(:document, project: project, organisation: organisation)
    version = create(:document_version, document: doc, organisation: organisation,
                                        title: title, description: description)
    doc.update!(current_version: version)
    doc.reload
  end

  describe 'associations' do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:creator).class_name('User') }
    it { is_expected.to belong_to(:current_version).class_name('DocumentVersion').optional }
    it { is_expected.to have_many(:document_versions).dependent(:destroy) }
  end

  describe 'Pflichtfelder (Model-Ebene)' do
    it 'ist mit project + creator + Tenant valide' do
      expect(build(:document, project: project, organisation: organisation)).to be_valid
    end

    it 'ist ungueltig ohne project' do
      doc = build(:document, project: nil, organisation: organisation)
      expect(doc).not_to be_valid
      expect(doc.errors[:project]).to be_present
    end

    it 'ist ungueltig ohne creator' do
      doc = build(:document, creator: nil, project: project, organisation: organisation)
      expect(doc).not_to be_valid
      expect(doc.errors[:creator]).to be_present
    end

    it 'ist valide OHNE current_version (optional)' do
      expect(build(:document, project: project, organisation: organisation, current_version: nil)).to be_valid
    end
  end

  describe 'DB-Constraints (defense in depth)' do
    it 'wirft NOT NULL bei fehlendem project, auch wenn die Model-Validierung umgangen wird' do
      doc = build(:document, project: nil, organisation: organisation)
      expect { doc.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
    end

    it 'wirft NOT NULL bei fehlendem creator, auch wenn die Model-Validierung umgangen wird' do
      doc = build(:document, creator: nil, project: project, organisation: organisation)
      expect { doc.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe 'Tenant-Isolation (acts_as_tenant)' do
    it 'sieht Dokumente eines anderen Tenants nicht im Default-Scope' do
      mine = create(:document, project: project, organisation: organisation)

      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        create(:document, project: other_project, organisation: other_org)
        expect(Document.all).not_to include(mine)
        expect(Document.count).to eq(1)
      end

      expect(Document.all).to include(mine)
      expect(Document.count).to eq(1)
    end
  end

  describe 'Cascade-Delete' do
    it 'loescht seine document_versions beim Zerstoeren (dependent: :destroy)' do
      doc = create(:document, project: project, organisation: organisation)
      create(:document_version, document: doc, organisation: organisation)
      create(:document_version, document: doc, organisation: organisation)

      Prosopite.pause # destroy cascade (fragments/blobs/jobs) produces a benign N+1
      expect { doc.destroy! }.to change(DocumentVersion, :count).by(-2)
    end
  end

  describe '#title / #description (Delegation an current_version)' do
    it 'liefert title/description der current_version' do
      doc = document_with_version(title: 'Echter Titel', description: 'Echte Beschreibung')
      expect(doc.title).to eq('Echter Titel')
      expect(doc.description).to eq('Echte Beschreibung')
    end

    it 'liefert nil OHNE current_version (kein NoMethodError auf nil)' do
      doc = create(:document, project: project, organisation: organisation)
      expect(doc.current_version).to be_nil
      expect(doc.title).to be_nil
      expect(doc.description).to be_nil
    end

    it 'title= schreibt auf die current_version durch' do
      doc = document_with_version(title: 'Alt')
      doc.title = 'Neu'
      expect(doc.current_version.reload.title).to eq('Neu')
    end

    it 'description= schreibt auf die current_version durch' do
      doc = document_with_version(description: 'Alt')
      doc.description = 'Neu'
      expect(doc.current_version.reload.description).to eq('Neu')
    end

    it 'title=/description= sind No-Op (kein Fehler) ohne current_version' do
      doc = create(:document, project: project, organisation: organisation)
      expect do
        doc.title = 'X'
        doc.description = 'Y'
      end.not_to raise_error
      expect(doc.title).to be_nil
    end

    # D6: the setter uses update! (not update), so an invalid value raises instead
    # of failing silently — that is what lets the actor map it to a failure Result
    # rather than the controller reporting a fake success.
    it 'title= raises on an invalid (blank) title instead of failing silently' do
      doc = document_with_version(title: 'Alt')

      expect { doc.title = '' }.to raise_error(ActiveRecord::RecordInvalid)
      expect(doc.current_version.reload.title).to eq('Alt')
    end
  end

  describe 'after_create_commit: track_document_created_in_project' do
    # The actual activity creation is covered in document_activity_spec; here only the
    # wiring guarantee: creating one reports to the project. Mutation (callback removed) -> red.
    it 'meldet die Erstellung an das Projekt (track_document_created)' do
      expect_any_instance_of(Project).to receive(:track_document_created).with(an_instance_of(Document))
      create(:document, project: project, organisation: organisation)
    end
  end
end
