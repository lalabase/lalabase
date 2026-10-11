# frozen_string_literal: true

class Dashboard::ProjectInfoComponent < ViewComponent::Base
  def initialize(project:, user:)
    @project = project
    @user = user
  end

  def should_render?
    true
  end

  private

  attr_reader :project, :user

  def custom_fields
    @custom_fields ||= project.ticket_attribute_definitions.active.ordered
  end

  def current_organisation
    project.organisation
  end
end
