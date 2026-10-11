# frozen_string_literal: true

require 'rails_helper'

# Pins the per-org project-chat beta gate on this nav component (the live tab bar
# in object-list controllers). GAP from the #39 review: the gate lives here but
# was untested, so a mutation removing it survived. Mirrors the sidebar spec's
# stubbed-helpers harness.
RSpec.describe NeoProjectNavigationComponent, type: :component do
  let(:organisation) { create(:organisation, code_indexing_enabled: true) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # Render with chats-area access GRANTED but every other area/permission denied,
  # so only the chat ("GPT") tab is in play → the per-org gate is the sole variable
  # deciding whether it shows. (Keeps the helper stub minimal: only the chats path
  # helper is reached.)
  def render_nav
    policy = instance_double(ProjectPolicy, show?: false, view_activities?: false)
    allow(policy).to receive(:area_access?).and_return(false)
    allow(policy).to receive(:area_access?).with(:chats, :read).and_return(true)
    allow(policy).to receive(:area_access?).with(:chats, :write).and_return(true)

    user = create(:user)
    allow(user).to receive(:has_permission_in_organisation?).and_return(false)
    allow(user).to receive(:account_admin_in?).and_return(false)

    helpers_double = double('helpers',
                            policy: policy, current_user: user,
                            controller_name: 'dashboard', action_name: 'index')

    component = described_class.new(project: project)
    allow(component).to receive(:helpers).and_return(helpers_double)
    render_inline(component)
  end

  # projekt_chat_abbau removed the GPT tab. Pinned as an ABSENCE in both directions
  # of the old gate (feature flag on, chat permission granted), because those were
  # exactly the conditions under which it used to appear -- and a tab that comes back
  # by accident comes back under them.
  it 'renders no GPT tab, whatever the flag and the chat permission say' do
    expect(render_nav.text).not_to include('GPT')

    organisation.update!(code_indexing_enabled: false)
    expect(render_nav.text).not_to include('GPT')
  end
end
