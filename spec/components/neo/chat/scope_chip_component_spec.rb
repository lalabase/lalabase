# frozen_string_literal: true

require 'rails_helper'

# S3a T5: when the scope chip shows itself at all. Everything else about the chip
# is covered where it acts (scope_selection_spec for the narrowing,
# assistant_chat_scope_spec for the write, assistant_panel_spec for the wiring);
# this is only the question of whether the row is worth its space.
RSpec.describe Neo::Chat::ScopeChipComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  # Same shape as the neighbouring component specs: the tenant is set in a
  # before hook, not an around block -- the suite resets it per example.
  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
  end

  let(:chat) do
    ActsAsTenant.with_tenant(organisation) { create(:chat, :org_thread, organisation: organisation, user: user) }
  end

  def project(name)
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: name) }
  end

  def rendered_for(chat_arg = chat)
    render_inline(described_class.new(chat: chat_arg, current_user: user,
                                      current_organisation: organisation))
    page.text
  end

  it 'shows itself once there is something to choose between' do
    project('Nordlicht Software')
    project('Kundenportal v2')

    expect(rendered_for).to include('Sucht in')
  end

  # A single readable project makes "all your projects" and "that project" the
  # same set: the control cannot narrow anything, and the row would be a line of
  # noise in a panel that is 380px wide by default.
  it 'stays away when a single project makes the choice meaningless' do
    project('Nordlicht Software')

    expect(rendered_for).to be_blank
  end

  it 'stays away with no projects at all' do
    expect(rendered_for).to be_blank
  end

  # Was: "stays away on a project thread". projekt_chat_abbau removed that kind of
  # thread, and with it the reason the chip was org-only -- a surface that already IS
  # one project has no width to narrow. What is left is the chip's own rule, pinned
  # above: it offers the projects the ASKER may read, never the organisation's list.
end
