# frozen_string_literal: true

require 'rails_helper'

# Regression guards for the privacy invariant: the Notizblock to-dos must NEVER
# be reachable via global search or the chat/RAG retrieval. Both systems are
# fail-closed opt-in, so exclusion is achieved simply by NOT registering
# PersonalTask anywhere. If a future change accidentally opts it in, these break.
RSpec.describe 'PersonalTask privacy exclusion', type: :model do
  it 'is not a searchable knowledge type (knowledge UNION search)' do
    expect(Knowledge::TypeRegistry.keys).not_to include('personal_task')
    expect(Knowledge::TypeRegistry::TYPES.keys).not_to include('personal_task')
  end

  it 'is not a chat/RAG content area (fail-closed registry -> nil)' do
    registry = Lalabase::ProjectRag::ContentAreaRegistry
    expect(registry.area_for('PersonalTask')).to be_nil
    expect(registry.registered_types).not_to include('PersonalTask')
  end

  it 'has no embedding wiring (never produces Fragments)' do
    # No polymorphic :fragments association -> nothing ever embeds a to-do.
    expect(PersonalTask.reflect_on_all_associations.map(&:name)).not_to include(:fragments)
    # And the model is not among the fragmentable types the project-context scope joins.
    expect(Fragment::FRAGMENTABLE_PROJECT_JOINS).not_to include('personal_tasks')
  end
end
