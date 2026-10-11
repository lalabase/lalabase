# frozen_string_literal: true

require 'rails_helper'

# S4 T2 step 4 (§7.3): the wrapper both chips live in. It has one job, and it is
# not a visual one -- it is the target of the update stream, so it has to be in
# the document even when there is nothing to show.
RSpec.describe Neo::Chat::ScopeRowComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

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

  def render_row(chat_arg = chat)
    render_inline(described_class.new(chat: chat_arg, current_user: user, current_organisation: organisation))
  end

  # THE reason this component exists. Both chips hide themselves, and a chip that
  # hides itself takes its element with it: without this wrapper, removing the
  # reference would delete the element the next request wants to replace, and
  # turbo_stream.replace on an id that is no longer in the document does nothing
  # at all -- no error, no update, just a chip that never comes back.
  #
  # Measured: with the wrapper's markup made conditional on the chips, this
  # example and the id one below are the only two in the suite that fail.
  it 'keeps its anchor in the document when neither chip applies' do
    render_row

    expect(page).to have_css("div#chat_#{chat.id}_scope_row", visible: :all)
    expect(page.text).to be_blank
  end

  # The positive half: an anchor that never has anything in it would satisfy the
  # example above just as well.
  it 'carries both chips once both apply' do
    first = project('Nordlicht Software')
    project('Kundenportal v2')
    referenced = ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: first, organisation: organisation, creator: user, title: 'Anmeldung schlaegt fehl')
    end
    ActsAsTenant.with_tenant(organisation) do
      chat.update!(scope_references: [Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: referenced.id)],
                   scope_project: first)
    end

    render_row(chat.reload)

    expect(page.text).to include('Bezug').and include('Sucht in')
    expect(page).to have_css("div#chat_#{chat.id}_scope_row select[name='chat[scope_project_id]']", visible: :all)
    expect(page).to have_css("div#chat_#{chat.id}_scope_row [data-reference-keys='Ticket:#{referenced.id}']",
                             visible: :all)
  end

  # The one thing that takes the anchor away. An unsaved chat has no id, so
  # dom_id would answer "new_chat_scope_row" for EVERY such render -- a fixed DOM
  # id, which is the trap this feature hit three times, last in production (#612).
  it 'renders no anchor at all for an unsaved chat, rather than a fixed one' do
    render_inline(described_class.new(chat: Chat.new(organisation: organisation, user: user),
                                      current_user: user, current_organisation: organisation))

    expect(page).to have_no_css('[id$=\'_scope_row\']', visible: :all)
    expect(page.text).to be_blank
  end

  # Both chips ask the same question of the same asker. Resolving it twice means
  # asking accessible_project_ids twice and plucking the active projects twice, on
  # a panel that renders on every page. The row is the shared parent, so it owns
  # the one resolution.
  it 'resolves the reach once for both chips' do
    project('Nordlicht Software')
    project('Kundenportal v2')

    expect(Lalabase::Tools::Scope).to receive(:for).once.and_call_original

    render_row
  end

  # Never a fixed id: the companion panel renders chat components on top of
  # whatever page the user is on, and a fixed id is how a replace ends up in the
  # wrong copy. Three times in this feature already, the last one in production.
  it 'derives its id from the chat' do
    second = ActsAsTenant.with_tenant(organisation) do
      create(:chat, :org_thread, organisation: organisation, user: user)
    end

    render_row
    first_id = page.find('div', match: :first, visible: :all)[:id]
    render_row(second)

    expect(first_id).to eq("chat_#{chat.id}_scope_row")
    expect(page).to have_css("div#chat_#{second.id}_scope_row", visible: :all)
  end

  # S2 (§8.1): the row is a pass-through for the one piece of REQUEST knowledge
  # the reference chip cannot have -- whether the request that produced this row
  # was a reference write, and the list should therefore come back open. The row
  # is what update.turbo_stream.erb builds, so a flag that stops here reaches
  # nothing.
  it 'passes the open-after-a-write flag down to the reference chip' do
    where = project('Nordlicht Software')
    two = ActsAsTenant.with_tenant(organisation) do
      2.times.map do |i|
        create(:ticket, project: where, organisation: organisation, creator: user, title: "Aufgabe #{i}")
      end
    end
    ActsAsTenant.with_tenant(organisation) do
      chat.update_column(:scope_references, two.map do |ticket|
        Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: ticket.id)
      end)
    end

    render_inline(described_class.new(chat: chat.reload, current_user: user,
                                      current_organisation: organisation, reference_expanded: true))

    expect(page).to have_css('details[open]', visible: :all)
  end

  # The default is closed, so a caller that says nothing does not accidentally
  # unfold the list on every page load.
  it 'leaves the list closed when nobody asked for it' do
    where = project('Nordlicht Software')
    two = ActsAsTenant.with_tenant(organisation) do
      2.times.map do |i|
        create(:ticket, project: where, organisation: organisation, creator: user, title: "Aufgabe #{i}")
      end
    end
    ActsAsTenant.with_tenant(organisation) do
      chat.update_column(:scope_references, two.map do |ticket|
        Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: ticket.id)
      end)
    end

    render_row(chat.reload)

    expect(page).to have_css('details', visible: :all)
    expect(page).to have_no_css('details[open]', visible: :all)
  end
end
