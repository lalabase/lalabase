# frozen_string_literal: true

class Dashboard::RecentNotesComponent < ViewComponent::Base
  def initialize(project:, user:, limit: nil)
    @project = project
    @user = user
    @limit = limit
  end

  def should_render?
    Current.project_policy(user, project).area_access?(:notes, :read)
  end

  private

  attr_reader :project, :user

  def recent_notes
    @recent_notes ||= project.notes.order(updated_at: :desc).limit(item_limit)
  end

  def item_limit
    Dashboards::LayoutEngine.effective_item_limit('key' => 'recent_notes', 'limit' => @limit)
  end

  def can_create_notes?
    Current.project_policy(user, project).area_access?(:notes, :write)
  end

  def current_organisation
    project.organisation
  end
end
