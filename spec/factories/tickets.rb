# frozen_string_literal: true

# spec/factories/tickets.rb
# == Schema Information
#
# Table name: tickets
#
#  id                       :uuid             not null, primary key
#  custom_attributes        :jsonb            not null
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  number                   :integer
#  summary                  :text
#  summary_generated_at     :datetime
#  ticket_type              :string           default("support"), not null
#  title                    :string           not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  creator_id               :uuid             not null
#  organisation_id          :uuid             not null
#  parent_id                :uuid
#  project_id               :uuid             not null
#  updater_id               :uuid
#
# Indexes
#
#  index_tickets_on_creator_id                       (creator_id)
#  index_tickets_on_custom_attributes                (custom_attributes) USING gin
#  index_tickets_on_custom_attrs_not_null            (((custom_attributes IS NOT NULL))) WHERE (custom_attributes IS NOT NULL)
#  index_tickets_on_org_and_custom_attrs_exists      (organisation_id, ((custom_attributes IS NOT NULL)))
#  index_tickets_on_org_created                      (organisation_id,created_at)
#  index_tickets_on_organisation_id_and_ticket_type  (organisation_id,ticket_type)
#  index_tickets_on_parent_id                        (parent_id)
#  index_tickets_on_project_and_custom_attrs_exists  (project_id, ((custom_attributes IS NOT NULL)))
#  index_tickets_on_project_created                  (project_id,created_at)
#  index_tickets_on_project_creator                  (project_id,creator_id)
#  index_tickets_on_project_id_and_number            (project_id,number) UNIQUE
#  index_tickets_on_project_title                    (project_id,title)
#  index_tickets_on_project_updated                  (project_id,updated_at)
#  index_tickets_on_ticket_type                      (ticket_type)
#  index_tickets_title_fts                           (to_tsvector('german'::regconfig, (title)::text)) USING gin
#
# Foreign Keys
#
#  fk_rails_...  (parent_id => tickets.id) ON DELETE => nullify
#

FactoryBot.define do
  factory :ticket do
    sequence(:title) { |n| "Ticket #{n}" }
    sequence(:content) { |n| "Content for ticket #{n}" }
    association :project
    association :creator, factory: :user
    association :organisation

    trait :with_custom_attributes do
      custom_attributes do
        {
          'status' => 'open',
          'priority' => 'normal'
        }
      end

      after(:build) do |ticket|
        # Ensure project has status/priority attribute definitions
        if ticket.project && !ticket.project.ticket_attribute_definitions.exists?(name: 'status')
          create(:ticket_attribute_definition,
                 project: ticket.project,
                 name: 'status',
                 field_type: 'select',
                 options: {
                   'allowed_values' => [
                     { 'value' => 'open', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
                     { 'value' => 'closed', 'labels' => { 'de' => 'Geschlossen', 'en' => 'Closed' } }
                   ]
                 })
          create(:ticket_attribute_definition,
                 project: ticket.project,
                 name: 'priority',
                 field_type: 'select',
                 options: {
                   'allowed_values' => [
                     { 'value' => 'low', 'labels' => { 'de' => 'Niedrig', 'en' => 'Low' } },
                     { 'value' => 'normal', 'labels' => { 'de' => 'Normal', 'en' => 'Normal' } },
                     { 'value' => 'high', 'labels' => { 'de' => 'Hoch', 'en' => 'High' } }
                   ]
                 })
        end
      end
    end
  end
end
