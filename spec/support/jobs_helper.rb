# frozen_string_literal: true

# Helper for job testing
RSpec.configure do |config|
  # This stubs all background job calls for tests
  config.before(:each) do
    # Stub ChatResponseJob (and its predecessor) to avoid Redis connection errors
    allow(ChatResponseJob).to receive(:perform_later).and_return(true)

    # Stub other background jobs as needed
    allow(DocumentVersionProcessingJob).to receive(:perform_later).and_return(true)
    allow(EmbeddingProcessingJob).to receive(:perform_later).and_return(true)
    allow(PostDocumentProcessingJob).to receive(:perform_later).and_return(true)
    allow(SummaryProcessingJob).to receive(:perform_later).and_return(true)
    allow(ProjectIndexerJob).to receive(:perform_later).and_return(true)
  end
end
