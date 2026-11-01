# frozen_string_literal: true

require 'rails_helper'

# What: Documentation::ResyncAll, behind `bin/rails documentation:resync_all`.
# Type: Service spec.
# Why:  A change to the renderer reaches a page only when its set is synced again, and a
#       poll skips every set whose repository did not move (DocumentationSyncJob
#       #skip_unchanged_poll?). After the deploy that moved the images of a page from the
#       repository host to the instance, every page cached before it still named the old
#       address. This is the one step that reaches them all: a MANUAL sync, which always
#       runs in full, for every set of every organisation.
RSpec.describe Documentation::ResyncAll do
  around do |example|
    adapter_was = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = adapter_was
  end

  def set_in(organisation)
    ActsAsTenant.with_tenant(organisation) do
      create(:documentation_set, project: create(:project, organisation: organisation))
    end
  end

  it 'enqueues a manual sync for every set of every organisation, and says how many' do
    first = set_in(create(:organisation))
    second = set_in(create(:organisation))

    count = nil
    expect { count = described_class.call }
      .to have_enqueued_job(DocumentationSyncJob).with(first.id, trigger: 'manual')
      .and have_enqueued_job(DocumentationSyncJob).with(second.id, trigger: 'manual')

    expect(count).to eq(2)
  end

  it 'does nothing, and says so, where there is no set' do
    expect { expect(described_class.call).to eq(0) }.not_to have_enqueued_job(DocumentationSyncJob)
  end
end
