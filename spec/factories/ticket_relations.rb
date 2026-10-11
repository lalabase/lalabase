# frozen_string_literal: true

# == Schema Information
#
# Table name: ticket_relations
#
#  id               :uuid             not null, primary key
#  delay_days       :integer
#  relation_type    :integer          not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  organisation_id  :uuid             not null
#  source_ticket_id :uuid             not null
#  target_ticket_id :uuid             not null
#
# Indexes
#
#  index_ticket_relations_on_organisation_id    (organisation_id)
#  index_ticket_relations_on_source_and_type    (source_ticket_id,relation_type)
#  index_ticket_relations_on_target_and_type    (target_ticket_id,relation_type)
#  index_ticket_relations_single_edge_per_pair  (LEAST(source_ticket_id, target_ticket_id), GREATEST(source_ticket_id, target_ticket_id), relation_type) UNIQUE WHERE (relation_type = ANY (ARRAY[1, 2]))
#  index_ticket_relations_unique_edge           (source_ticket_id,target_ticket_id,relation_type) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (source_ticket_id => tickets.id) ON DELETE => cascade
#  fk_rails_...  (target_ticket_id => tickets.id) ON DELETE => cascade
#
FactoryBot.define do
  factory :ticket_relation do
    association :source_ticket, factory: :ticket
    target_ticket { association :ticket, project: source_ticket.project, organisation: source_ticket.organisation }
    # acts_as_tenant overwrites this with the current tenant on create; without a
    # tenant it is the tickets' organisation.
    organisation { source_ticket.organisation }
    relation_type { :blocks }
  end
end
