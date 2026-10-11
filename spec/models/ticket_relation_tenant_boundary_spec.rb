# frozen_string_literal: true

require 'rails_helper'

# The tenant boundary of ticket relations (doc/ticket_relations_plan.md, revision 4, §3.1):
# relations may cross projects, never organisations. acts_as_tenant writes organisation_id
# from the CURRENT tenant, not from the tickets, so the model checks that both tickets belong
# to the row's organisation. Without that check a job or console run under another tenant
# would write a row that the right tenant can never see.
RSpec.describe TicketRelation, :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }
  let(:foreign_organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:foreign_project) do
    ActsAsTenant.with_tenant(foreign_organisation) { create(:project, organisation: foreign_organisation) }
  end
  let(:ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) } }
  let(:other_ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) } }
  let(:foreign_ticket) { ActsAsTenant.with_tenant(foreign_organisation) { create(:ticket, project: foreign_project) } }
  let(:second_foreign_ticket) do
    ActsAsTenant.with_tenant(foreign_organisation) { create(:ticket, project: foreign_project) }
  end

  after { ActsAsTenant.current_tenant = nil }

  def organisation_mismatch?(record)
    record.validate
    record.errors.added?(:base, :organisation_mismatch)
  end

  it 'rejects a ticket of another organisation as the target' do
    ActsAsTenant.with_tenant(organisation) do
      record = described_class.new(source_ticket: ticket, target_ticket: foreign_ticket, relation_type: :blocks)

      expect(organisation_mismatch?(record)).to be(true)
      expect { record.save! }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  it 'rejects a ticket of another organisation as the source' do
    ActsAsTenant.with_tenant(organisation) do
      record = described_class.new(source_ticket: foreign_ticket, target_ticket: ticket, relation_type: :relates_to)

      expect(organisation_mismatch?(record)).to be(true)
    end
  end

  it 'rejects two tickets of another organisation, which the current tenant would otherwise stamp as its own' do
    ActsAsTenant.with_tenant(organisation) do
      record = described_class.new(source_ticket: foreign_ticket, target_ticket: second_foreign_ticket, relation_type: :blocks)

      expect(organisation_mismatch?(record)).to be(true)
      expect(record.organisation_id).to eq(organisation.id)
    end
  end

  it 'rejects a row whose organisation is not the one of its tickets when no tenant is set' do
    ActsAsTenant.without_tenant do
      record = described_class.new(organisation: foreign_organisation, source_ticket: ticket,
                                   target_ticket: other_ticket, relation_type: :blocks)

      expect(organisation_mismatch?(record)).to be(true)
    end
  end

  it 'accepts the same row with the tickets organisation when no tenant is set' do
    ActsAsTenant.without_tenant do
      record = described_class.new(organisation: organisation, source_ticket: ticket,
                                   target_ticket: other_ticket, relation_type: :blocks)

      expect(record).to be_valid
    end
  end

  it 'does not resolve a foreign ticket id under the current tenant' do
    ActsAsTenant.with_tenant(organisation) do
      record = described_class.new(source_ticket: ticket, target_ticket_id: foreign_ticket.id, relation_type: :blocks)

      expect(record).not_to be_valid
      expect { record.save! }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  # Review round 1 (30.09.2026): the duplicate checks asked through the tenant scope, so a
  # row of this organisation, edited under another tenant, searched the wrong organisation,
  # passed validation and ran into the unique index. Since review step 2 the ends and the type
  # of a saved relation are read-only, so that edit cannot happen under any tenant; the checks
  # still name the row's own organisation (next example).
  it 'refuses to edit a saved relation into a duplicate, also under another tenant' do
    row = ActsAsTenant.with_tenant(organisation) do
      described_class.create!(source_ticket: ticket, target_ticket: other_ticket, relation_type: :precedes)
      described_class.create!(source_ticket: ticket, target_ticket: other_ticket, relation_type: :blocks)
    end

    ActsAsTenant.with_tenant(foreign_organisation) do
      expect { row.relation_type = :precedes }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    end
  end

  # The duplicate checks leave the tenant scope on purpose, so they must name the
  # organisation themselves: no query across all tenants.
  it 'asks for duplicates only inside one organisation' do
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('FROM "ticket_relations"') }
    ActsAsTenant.with_tenant(organisation) do
      record = described_class.new(source_ticket: ticket, target_ticket: other_ticket, relation_type: :relates_to)
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { record.validate }
    end

    expect(queries.size).to eq(2)
    expect(queries).to all(include('"ticket_relations"."organisation_id" = '))
  end

  it 'keeps the relations of another organisation out of sight' do
    ActsAsTenant.with_tenant(foreign_organisation) do
      described_class.create!(source_ticket: foreign_ticket, target_ticket: second_foreign_ticket, relation_type: :blocks)
    end

    ActsAsTenant.with_tenant(organisation) do
      expect(described_class.count).to eq(0)
    end
  end
end
