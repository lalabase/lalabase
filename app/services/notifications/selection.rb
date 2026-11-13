# frozen_string_literal: true

# The rows behind a selection of the inbox above the organisations, for an
# action on all of them (the bulk bar, AllInboxesController#change_selection):
# { organisation => [ids] }, organisations in the order of their ids.
#
# Stays inside the tenant, as every read for a signed-in person should: it
# goes through the organisations the person is an ACTIVE member of and asks, in
# each of them under ActsAsTenant.with_tenant, the policy scope of
# notifications (NotificationPolicy::Scope: the person's own rows there that
# they may still see). No query reads across organisations.
#
# Only in-app rows count: a mail row is no row of an inbox. Every other id
# (malformed, another person's, hidden, gone, of an organisation the person has
# left) is left out without a word, so no answer tells one from the other, and
# an organisation in which nothing was found is not named.
module Notifications
  class Selection
    def self.call(user:, ids:)
      ids = Array(ids).grep(String).filter_map { |id| Lalabase::Uuid.dashed(id) }
      return {} if ids.empty?

      user.active_organisations.order(:id).each_with_object({}) do |organisation, found|
        rows = selected_rows_in_organisation(user, organisation, ids)
        found[organisation] = rows if rows.any?
      end
    end

    # Named so the loop per organisation has its own frame in the Prosopite
    # stack (spec/support/prosopite.rb): bounded by the person's organisations.
    def self.selected_rows_in_organisation(user, organisation, ids)
      ActsAsTenant.with_tenant(organisation) do
        Pundit.policy_scope!(user, user.notifications).channel_in_app.where(id: ids).order(:id).pluck(:id)
      end
    end
    private_class_method :selected_rows_in_organisation
  end
end
