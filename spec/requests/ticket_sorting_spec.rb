# frozen_string_literal: true

require 'rails_helper'

# Regression guard: clicking the Status / Priority column headers used to map onto the
# dropped ticket_statuses / ticket_priorities tables (ORDER BY ticket_statuses → 500).
# Both attributes now live in JSONB custom_attributes and sort by configured option order.
RSpec.describe 'Ticket list sorting by status and priority', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { ActsAsTenant.with_tenant(organisation) { create(:user) } }
  let(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.current_tenant = organisation
    membership
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket_attribute_definition, :select,
             project: project,
             name: 'priority',
             options: { 'allowed_values' => [
               { 'value' => 'low', 'labels' => { 'de' => 'Niedrig', 'en' => 'Low' } },
               { 'value' => 'high', 'labels' => { 'de' => 'Hoch', 'en' => 'High' } }
             ] })
      create(:ticket_attribute_definition, :select,
             project: project,
             name: 'status',
             options: { 'allowed_values' => [
               { 'value' => 'open', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
               { 'value' => 'closed', 'labels' => { 'de' => 'Geschlossen', 'en' => 'Closed' } }
             ] })
    end
    sign_in user
  end

  def create_ticket(title, attrs)
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, creator: user, title: title, custom_attributes: attrs)
    end
  end

  it 'returns 200 (not 500) when sorting by priority ascending' do
    get organisation_project_tickets_path(organisation, project),
        params: { sort: { column: 'priority', direction: 'asc' } }

    expect(response).to have_http_status(:ok)
  end

  it 'returns 200 (not 500) when sorting by status descending' do
    get organisation_project_tickets_path(organisation, project),
        params: { sort: { column: 'status', direction: 'desc' } }

    expect(response).to have_http_status(:ok)
  end

  # The list partial is requested directly via its Turbo Frame so the response is just
  # the results table (the full page renders both desktop and mobile partials, which
  # would make a body.index(...) comparison ambiguous).
  def get_sorted_table(direction, column: 'priority')
    get organisation_project_tickets_path(organisation, project),
        params: { sort: { column: column, direction: direction } },
        headers: { 'Turbo-Frame' => 'tickets_list_frame' }
  end

  it 'orders the rows by configured priority order (low before high on asc)' do
    create_ticket('HighPrioTicket', { 'priority' => 'high' })
    create_ticket('LowPrioTicket', { 'priority' => 'low' })

    get_sorted_table('asc')

    expect(response).to have_http_status(:ok)
    expect(response.body.index('LowPrioTicket')).to be < response.body.index('HighPrioTicket')
  end

  it 'reverses the configured order on desc (high before low)' do
    create_ticket('HighPrioTicket', { 'priority' => 'high' })
    create_ticket('LowPrioTicket', { 'priority' => 'low' })

    get_sorted_table('desc')

    expect(response).to have_http_status(:ok)
    expect(response.body.index('HighPrioTicket')).to be < response.body.index('LowPrioTicket')
  end

  # The table header links carry the 'custom_'-prefixed column key, so the real
  # click path sends sort[column]=custom_priority — it must sort identically.
  it 'sorts via the prefixed column key used by the header link' do
    create_ticket('HighPrioTicket', { 'priority' => 'high' })
    create_ticket('LowPrioTicket', { 'priority' => 'low' })

    get_sorted_table('asc', column: 'custom_priority')

    expect(response).to have_http_status(:ok)
    expect(response.body.index('LowPrioTicket')).to be < response.body.index('HighPrioTicket')
  end
end
