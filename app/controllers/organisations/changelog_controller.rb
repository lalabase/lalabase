# frozen_string_literal: true

class Organisations::ChangelogController < Organisations::BaseController
  def show
    authorize :changelog, :show?

    @entries = Changelog::EntryLoader.call
    @grouped_entries = @entries.group_by { |e| e.date.beginning_of_month }

    current_user.update_column(:changelog_last_read_at, Time.current)
  end
end
