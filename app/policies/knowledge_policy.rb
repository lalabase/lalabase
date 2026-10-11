# frozen_string_literal: true

class KnowledgePolicy < ApplicationPolicy
  def index?
    # record is @project. Access to the knowledge view holds if the user may read
    # ANY registered knowledge type's area — derived from Knowledge::TypeRegistry so a
    # new knowledge type never needs a policy edit again. This
    # mirrors the controller's accessible_type_keys gate, so the two cannot disagree.
    project_policy = ProjectPolicy.new(user, record)
    Knowledge::TypeRegistry.keys.any? do |key|
      project_policy.area_access?(Knowledge::TypeRegistry.fetch(key)[:access_area], :read)
    end
  end
end
