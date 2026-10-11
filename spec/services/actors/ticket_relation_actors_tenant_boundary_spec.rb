# frozen_string_literal: true

require 'rails_helper'

# The tenant boundary of the two relation actors (doc/ticket_relations_plan.md, revision 4,
# §3.1). The controller resolves the other ticket through policy_scope(Ticket) first (PR 2);
# these examples hold the second line: even with a foreign ticket or a foreign relation id in
# hand, the actors write nothing across organisations.
RSpec.describe 'Ticket relation actors across organisations', :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:foreign_organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:foreign_project) do
    ActsAsTenant.with_tenant(foreign_organisation) { create(:project, organisation: foreign_organisation) }
  end
  let(:ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) } }
  let(:foreign_ticket) { ActsAsTenant.with_tenant(foreign_organisation) { create(:ticket, project: foreign_project) } }
  let(:second_foreign_ticket) do
    ActsAsTenant.with_tenant(foreign_organisation) { create(:ticket, project: foreign_project) }
  end

  after { ActsAsTenant.current_tenant = nil }

  %w[blocks blocked_by relates_to].each do |kind|
    it "refuses to link a ticket of another organisation (#{kind})" do
      result = ActsAsTenant.with_tenant(organisation) do
        Actors::CreateTicketRelation.call(ticket: ticket, other_ticket: foreign_ticket, kind: kind, current_user: user)
      end

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      expect(ActsAsTenant.without_tenant { TicketRelation.count }).to eq(0)
    end
  end

  it 'does not remove a relation of another organisation, even through a foreign ticket' do
    foreign_relation = ActsAsTenant.with_tenant(foreign_organisation) do
      TicketRelation.create!(source_ticket: foreign_ticket, target_ticket: second_foreign_ticket, relation_type: :blocks)
    end

    results = ActsAsTenant.with_tenant(organisation) do
      Prosopite.pause do
        [ticket, foreign_ticket].map do |shown|
          Actors::DestroyTicketRelation.call(ticket: shown, relation_id: foreign_relation.id, current_user: user).code
        end
      end
    end

    expect(results).to eq(%i[not_found not_found])
    expect(ActsAsTenant.without_tenant { TicketRelation.exists?(foreign_relation.id) }).to be(true)
  end
end
