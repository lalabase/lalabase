# frozen_string_literal: true

# Gate for the documentation browsing area. Record is the Project; access is the
# new :documentation area (read to browse). Mirrors KnowledgePolicy's shape.
class DocumentationPolicy < ApplicationPolicy
  def index?
    ProjectPolicy.new(user, record).area_access?(:documentation, :read)
  end
end
