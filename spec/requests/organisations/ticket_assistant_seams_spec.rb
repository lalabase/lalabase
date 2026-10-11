# frozen_string_literal: true

require 'rails_helper'

# What:  The two seams by which a ticket page reaches the assistant panel
#        (S4 T2, plan §7.3): the "Assistent" button that SETS a reference on
#        click (step 5a), and the marker by which the page NAMES its object so
#        the panel can offer to take it over without a click (step 5b).
# Type:  Request spec.
# Why:   Both exist for the same reason and neither is visible from its own
#        markup: the panel is a permanent node, so the server can never re-render
#        it and it has no other way of learning what page it is standing on. Both
#        also have to appear exactly where the assistant does -- a door to a lane
#        that is not there is the shape of defect the panel's gate exists to
#        prevent -- which is why the negative example below covers them together.
RSpec.describe 'Ticket page assistant seams (S4 T2 steps 5a and 5b)', type: :request do
  # The ONE variable between the two examples below. Not the user's rights: an
  # admin passes the permission half of the gate by bypass, so varying the role
  # would vary the ticket page too and the negative example would prove nothing
  # about this button.
  let(:assistant_enabled) { true }

  let(:organisation) do
    create(:organisation, assistant_enabled: assistant_enabled, ai_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef')
  end

  let(:role) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:admin_role, organisation: organisation)
      create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
      role
    end
  end

  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: create(:user), title: 'Anmeldung')
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def sign_in_member
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    sign_in user
    user
  end

  def button
    Nokogiri::HTML.fragment(response.body).at_css('[data-controller~="assistant-trigger"][data-assistant-trigger-id-value]')
  end

  def context_marker
    Nokogiri::HTML.fragment(response.body).at_css('[data-assistant-context]')
  end

  it 'hands the page\'s ticket to the panel over the window-event seam' do
    sign_in_member

    get organisation_project_ticket_path(organisation, project, ticket)

    expect(response).to have_http_status(:ok)
    expect(button).to be_present
    # Type AND id since the Bezugs-Sammlung (S1, §8.3): the trigger composes the
    # composite key "Ticket:<uuid>" out of the pair, and that key is what the
    # collection is addressed by everywhere -- URL segment, form body,
    # data-reference-keys. A bare id would leave the panel guessing what it is an
    # id OF.
    expect(button['data-assistant-trigger-type-value']).to eq('Ticket')
    expect(button['data-assistant-trigger-id-value']).to eq(ticket.id)
    expect(button['data-action']).to include('assistant-trigger#adopt')
  end

  # Below the panel's breakpoint there is no companion lane on this device, so
  # this button opens a door to nowhere -- and the click still reached the server:
  # it wrote the reference and marked the panel open in the cookie, with nothing
  # on screen either time. The lane's own node carries the same pair of classes.
  #
  # Only the MARKUP half is asserted here, and that is not laziness: the
  # controller refuses the same thing a second time (canOpen), but the system
  # driver runs with stylesheets disabled (spec/support/capybara.rb), so
  # `offsetParent` is never null there and no browser example in this suite can
  # observe that guard. The same is true of the guard toggle() has carried since
  # S3a T4. Asserting the class is what can honestly be pinned.
  it 'is gated on the same breakpoint as the panel it opens' do
    sign_in_member

    get organisation_project_ticket_path(organisation, project, ticket)

    wrapper = button.ancestors('div').first
    expect(wrapper['class']).to include('hidden').and include('lg:block')
  end

  # Step 5b (§7.3): the page names its object so the panel can OFFER it. Not a
  # Stimulus value like the button next door -- a click has a receiver that reads
  # its own controller, this has none: after a navigation the panel has to search
  # the page for it, and a name that hangs off a controller would be the wrong
  # thing to search for (plan Rev. 13).
  it 'names the page\'s ticket so the panel can offer it without a click' do
    sign_in_member

    get organisation_project_ticket_path(organisation, project, ticket)

    expect(context_marker).to be_present
    expect(context_marker['data-assistant-context']).to eq(ticket.id)
    expect(context_marker['data-assistant-context-type']).to eq('Ticket')
    expect(context_marker['data-assistant-context-label']).to eq("##{ticket.number} Anmeldung")
  end

  # BOTH roots of #ticket_display_frame carry it, which is the whole reason the
  # attribute pair became AssistantContextHelper. The frame normally holds
  # _ticket_display; TicketsController#render_summary_success fills the SAME frame
  # with _ticket_content_for_frame alone, and a marker that lived only on the
  # outer wrapper was gone from the moment somebody generated a summary -- the
  # panel then withdrew the offer while the user was still standing on the ticket,
  # and nothing anywhere went red.
  #
  # Asserted as a COUNT and not with at_css, because at_css answers the first
  # match and would be just as green with the inner one missing.
  #
  # The bound and the gate are not re-asserted here: they belong to the helper and
  # are pinned in spec/helpers/assistant_context_helper_spec.rb. What THIS spec
  # owns is that the page asks the helper at all, at both roots.
  it 'names its ticket at both roots of the display frame' do
    sign_in_member

    get organisation_project_ticket_path(organisation, project, ticket)

    markers = Nokogiri::HTML.fragment(response.body).css('[data-assistant-context]')
    expect(markers.size).to eq(2)
    expect(markers.map { |m| m['data-assistant-context'] }).to all(eq(ticket.id))
    expect(markers.map { |m| m['data-assistant-context-label'] })
      .to all(eq("##{ticket.number} Anmeldung"))
  end

  # The negative half with the positive one right above it: same user, same
  # rights, same page, and the operator's assistant flag off. Without the lane
  # there is nothing for this button to open, and a door to nowhere is exactly
  # what the panel's own gate exists to prevent.
  context 'when the operator has not enabled the assistant' do
    let(:assistant_enabled) { false }

    it 'stays away where the assistant itself stays away' do
      sign_in_member

      get organisation_project_ticket_path(organisation, project, ticket)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ticket.title)
      expect(button).to be_nil
      expect(context_marker).to be_nil
    end
  end
end
