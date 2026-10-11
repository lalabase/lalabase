# frozen_string_literal: true

# == Schema Information
#
# Table name: ticket_attribute_definitions
#
#  id               :uuid             not null, primary key
#  active           :boolean          default(TRUE)
#  field_type       :string           not null
#  labels           :jsonb
#  name             :string           not null
#  options          :jsonb
#  position         :integer          default(0)
#  section          :string
#  system           :boolean          default(FALSE)
#  validation_rules :jsonb
#  visibility_rules :jsonb
#  width            :string           default("full")
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  project_id       :uuid             not null
#
# Indexes
#
#  index_ticket_attribute_definitions_on_position               (position)
#  index_ticket_attribute_definitions_on_project_id             (project_id)
#  index_ticket_attribute_definitions_on_project_id_and_active  (project_id,active)
#  index_ticket_attribute_definitions_on_project_id_and_name    (project_id,name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id)
#
FactoryBot.define do
  factory :ticket_attribute_definition do
    project
    sequence(:name) { |n| "attribute_#{n}" }
    field_type { 'text' }
    labels { { 'de' => name.humanize, 'en' => name.humanize } }
    options { {} }
    validation_rules { {} }
    visibility_rules { {} }
    position { 0 }
    active { true }
    system { false }
    width { 'full' }

    trait :select do
      field_type { 'select' }
      options do
        {
          'allowed_values' => [
            { 'value' => 'option1', 'labels' => { 'de' => 'Option 1', 'en' => 'Option 1' } },
            { 'value' => 'option2', 'labels' => { 'de' => 'Option 2', 'en' => 'Option 2' } }
          ]
        }
      end
    end

    trait :required do
      validation_rules { { 'required' => true } }
    end

    trait :checkbox do
      field_type { 'checkbox' }
    end
  end
end
