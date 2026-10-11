# frozen_string_literal: true

# Shared setup for the bulk edit specs (doc/ticket_bulk_edit_plan.md): a
# project with a status, a deadline and a tag, an admin writer, and members
# who share ONE admin role (a second admin role in the same organisation
# fails on the role title). Tenant-safe: every helper sets the tenant itself,
# so a let! that runs before the before block still works.
#
# The specs tagged :bulk_edit pause Prosopite: the actor walks the tickets
# one at a time through the model on purpose (D13), which the N+1 detector
# reads as a loop of queries, which it is.
module BulkEditHelpers
  def bulk_admin_role
    @bulk_admin_role ||= ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) }
  end

  def bulk_member(user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: bulk_admin_role)
    end
  end

  def bulk_project_setup
    ActsAsTenant.current_tenant = organisation
    bulk_member(writer)
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', position: 1,
                                         labels: { 'de' => 'Status', 'en' => 'Status' },
                                         options: { 'allowed_values' => [
                                           { 'value' => 'open', 'labels' => { 'de' => 'offen', 'en' => 'open' } },
                                           { 'value' => 'wip', 'labels' => { 'de' => 'in Arbeit', 'en' => 'in progress' } }
                                         ] })
    create(:ticket_attribute_definition, project: project, name: 'due_date', field_type: 'date', position: 2,
                                         labels: { 'de' => 'Frist', 'en' => 'Due' }, options: { 'deadline' => true })
    create(:tag, name: 'backend', organisation: organisation)
  end

  def bulk_ticket(attrs = { 'status' => 'open' }, title: 'Ticket')
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: writer, title: title, custom_attributes: attrs)
    end
  end
end

# Group-level hooks, after the suite's own Prosopite.scan (a config-level
# before would run first and be undone by it). Not an around hook, as
# spec/requests/inbox_bulk_actions_spec.rb notes.
RSpec.shared_context 'bulk edit', :bulk_edit do
  before { Prosopite.pause }
  after { Prosopite.resume }
end

RSpec.configure do |config|
  config.include BulkEditHelpers
  config.include_context 'bulk edit', :bulk_edit
end
