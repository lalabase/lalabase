# frozen_string_literal: true

# Headless policy (no model) — every authenticated user may see the changelog.
class ChangelogPolicy < Struct.new(:user, :changelog)
  def show?
    true
  end
end
