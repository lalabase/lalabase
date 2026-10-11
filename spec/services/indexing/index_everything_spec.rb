# frozen_string_literal: true

require 'rails_helper'

# What: Indexing::IndexEverything, the one-off for the stock after
#   doc/notizen_immer_indexiert_plan.md.
# Type: service spec; the job is stubbed at its class (the test queue adapter is
#   Solid Queue, which keeps no enqueued_jobs list), no provider is called.
# Why: the switch is gone from the forms, so a note or version left opted out
#   would stay unfindable forever with no control to change it. The run must
#   flip every such row, enqueue the job for it and for every row never indexed,
#   leave indexed rows alone, and enqueue NOTHING where the embedding lane is not
#   usable (a job that would only fail), while still flipping the flag there so
#   the next save indexes.
RSpec.describe Indexing::IndexEverything do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:available) { instance_double(Lalabase::Llm::FeatureRegistry::Availability, available?: true, reason: nil) }
  let(:refused) { instance_double(Lalabase::Llm::FeatureRegistry::Availability, available?: false, reason: :no_credential) }

  before { allow(EmbeddingProcessingJob).to receive(:perform_later) }

  def note(**attrs)
    ActsAsTenant.with_tenant(organisation) do
      create(:note, { project: project, organisation: organisation, creator: user }.merge(attrs))
    end
  end

  def version(**attrs)
    ActsAsTenant.with_tenant(organisation) do
      Prosopite.pause do
        doc = create(:document, project: project, organisation: organisation, creator: user)
        create(:document_version, { document: doc, organisation: organisation }.merge(attrs))
      end
    end
  end

  def job_for(klass, record)
    have_received(:perform_later).with(record_class: klass, record_id: record.id, fragment_association: :fragments)
  end

  it 'flips the opted-out rows and enqueues the job for them and for the never-indexed ones' do
    allow(organisation).to receive(:ai_available_for?).with(:content_indexing).and_return(available)
    opted_out = note(create_embeddings: false, embeddings_creation_flag: true)
    never = note(create_embeddings: true, embeddings_creation_flag: nil)
    done = note(create_embeddings: true, embeddings_creation_flag: true)
    opted_out_version = version(create_embeddings: false, embeddings_creation_flag: true)
    done_version = version(create_embeddings: true, embeddings_creation_flag: true)

    result = described_class.call(organisation: organisation)

    expect(result.flipped).to eq(2)
    expect(result.enqueued).to eq(3)
    expect(result.reason).to be_nil
    expect(opted_out.reload.create_embeddings).to be(true)
    expect(opted_out_version.reload.create_embeddings).to be(true)
    expect(EmbeddingProcessingJob).to job_for(Note, opted_out)
    expect(EmbeddingProcessingJob).to job_for(Note, never)
    expect(EmbeddingProcessingJob).to job_for(DocumentVersion, opted_out_version)
    expect(EmbeddingProcessingJob).not_to job_for(Note, done)
    expect(EmbeddingProcessingJob).not_to job_for(DocumentVersion, done_version)
    expect(EmbeddingProcessingJob).to have_received(:perform_later).exactly(3).times
  end

  it 'treats a NULL opt-in as opted out: the document actors used to store nil when the form hid the switch' do
    allow(organisation).to receive(:ai_available_for?).with(:content_indexing).and_return(available)
    nil_version = version(create_embeddings: nil, embeddings_creation_flag: true)
    nil_note = note(create_embeddings: nil, embeddings_creation_flag: true)

    result = described_class.call(organisation: organisation)

    expect(result.flipped).to eq(2)
    expect(nil_version.reload.create_embeddings).to be(true)
    expect(nil_note.reload.create_embeddings).to be(true)
    expect(EmbeddingProcessingJob).to job_for(DocumentVersion, nil_version)
    expect(EmbeddingProcessingJob).to job_for(Note, nil_note)
  end

  it 'leaves a flipped row pending, so a run without a usable lane is caught up by the next one' do
    allow(organisation).to receive(:ai_available_for?).with(:content_indexing).and_return(refused, available)
    # Indexed once, then edited while opted out: the completion flag survived the purge.
    stale = note(create_embeddings: false, embeddings_creation_flag: true)

    first = described_class.call(organisation: organisation)
    expect(first.enqueued).to eq(0)
    expect(stale.reload.create_embeddings).to be(true)
    expect(stale.embeddings_creation_flag).to be_nil
    expect(EmbeddingProcessingJob).not_to have_received(:perform_later)

    second = described_class.call(organisation: organisation)
    expect(second.flipped).to eq(0)
    expect(second.enqueued).to eq(1)
    expect(EmbeddingProcessingJob).to job_for(Note, stale)
  end

  it 'flips the flag but enqueues nothing where the embedding lane is not usable' do
    allow(organisation).to receive(:ai_available_for?).with(:content_indexing).and_return(refused)
    opted_out = note(create_embeddings: false, embeddings_creation_flag: nil)

    result = described_class.call(organisation: organisation)

    expect(result.flipped).to eq(1)
    expect(result.enqueued).to eq(0)
    expect(result.reason).to eq(:no_credential)
    expect(opted_out.reload.create_embeddings).to be(true)
    expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
  end

  it 'touches no row of another organisation' do
    other = create(:organisation)
    other_project = ActsAsTenant.with_tenant(other) { create(:project, organisation: other) }
    other_note = ActsAsTenant.with_tenant(other) do
      create(:note, project: other_project, organisation: other, creator: user, create_embeddings: false)
    end
    allow(organisation).to receive(:ai_available_for?).with(:content_indexing).and_return(available)

    described_class.call(organisation: organisation)

    expect(other_note.reload.create_embeddings).to be(false)
    expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
  end

  it 'is idempotent: a second run flips nothing and enqueues only what is still pending' do
    allow(organisation).to receive(:ai_available_for?).with(:content_indexing).and_return(available)
    flipped = note(create_embeddings: false, embeddings_creation_flag: true)
    never = note(create_embeddings: true, embeddings_creation_flag: nil)
    described_class.call(organisation: organisation)
    # The job is a stub here; the service would have settled the flipped row by now.
    Note.unscoped.where(id: flipped.id).update_all(embeddings_creation_flag: true)
    RSpec::Mocks.space.proxy_for(EmbeddingProcessingJob).reset
    allow(EmbeddingProcessingJob).to receive(:perform_later)

    result = described_class.call(organisation: organisation)

    expect(result.flipped).to eq(0)
    expect(result.enqueued).to eq(1)
    expect(EmbeddingProcessingJob).to job_for(Note, never)
    expect(EmbeddingProcessingJob).to have_received(:perform_later).once
  end
end
