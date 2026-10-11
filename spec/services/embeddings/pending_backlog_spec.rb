# frozen_string_literal: true

require 'rails_helper'

# S3 KI-Kontingent (test 17): the monthly catch-up serves organisations OLDEST
# backlog first. This pins the ordering and that fully-embedded orgs drop out.
RSpec.describe Embeddings::PendingBacklog do
  def pending_note(org, created_at:)
    ActsAsTenant.with_tenant(org) do
      create(:note, organisation: org, project: create(:project, organisation: org),
                    create_embeddings: true, embeddings_creation_flag: false,
                    plain_text_version: 'pending content', created_at: created_at)
    end
  end

  it 'orders organisations by their oldest pending record first' do
    org_old = create(:organisation)
    org_new = create(:organisation)
    pending_note(org_new, created_at: 1.day.ago)
    pending_note(org_old, created_at: 20.days.ago)

    result = described_class.organisation_ids_oldest_first
    expect(result).to include(org_old.id, org_new.id)
    expect(result.index(org_old.id)).to be < result.index(org_new.id)
  end

  it 'excludes an organisation whose records are all embedded' do
    org = create(:organisation)
    ActsAsTenant.with_tenant(org) do
      create(:note, organisation: org, project: create(:project, organisation: org),
                    create_embeddings: true, embeddings_creation_flag: true,
                    plain_text_version: 'done')
    end
    expect(described_class.organisation_ids_oldest_first).not_to include(org.id)
  end

  # Pins the Ticket relation specifically: tickets ALWAYS embed (no create_embeddings
  # gate), so dropping Ticket from pending_relations would silently stop surfacing
  # orgs whose only backlog is tickets. update_column writes the raw flag column the
  # SQL query reads (the model reader is overridden to always-true).
  it 'surfaces an org whose only pending backlog is a Ticket' do
    org = create(:organisation)
    ActsAsTenant.with_tenant(org) do
      ticket = create(:ticket, organisation: org, project: create(:project, organisation: org))
      ticket.update_column(:embeddings_creation_flag, false)
    end
    expect(described_class.organisation_ids_oldest_first).to include(org.id)
  end
end
