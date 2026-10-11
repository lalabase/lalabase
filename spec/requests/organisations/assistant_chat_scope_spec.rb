# frozen_string_literal: true

require 'rails_helper'

# S3a T5 (§9.3): the write path of the scope chip. The read side lives in
# Tools::Scope (scope_selection_spec) and can only ever narrow; what has to hold
# HERE is that nothing outside the user's own project list ever gets stored.
#
# Why that matters even though the reach is intersected with rights anyway: a
# stored id is also what the chip PRINTS. A project name is exactly what the
# sidebar withholds from someone without access, so accepting an arbitrary id
# would turn a filter into a way to read one.
RSpec.describe 'Assistant chat scope (S3a T5)', type: :request do
  let(:organisation) do
    create(:organisation, assistant_enabled: true, ai_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-org-own-1234567890abcdef')
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:assistant_role) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation, title: "Assistant #{SecureRandom.hex(3)}")
      create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
      role
    end
  end

  let(:owner) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: assistant_role, active: true)
    end
    user
  end

  let(:admin) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
    user
  end

  let!(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Nordlicht Software') }
  end

  let(:chat) do
    ActsAsTenant.with_tenant(organisation) { create(:chat, :org_thread, organisation: organisation, user: owner) }
  end

  def stored_scope
    ActsAsTenant.with_tenant(organisation) { Chat.find(chat.id).scope_project_id }
  end

  it 'stores a project the user may read' do
    sign_in admin

    admins_chat = ActsAsTenant.with_tenant(organisation) do
      create(:chat, :org_thread, organisation: organisation, user: admin)
    end
    patch organisation_assistant_chat_path(organisation, admins_chat),
          params: { chat: { scope_project_id: project.id } }

    expect(ActsAsTenant.with_tenant(organisation) { Chat.find(admins_chat.id).scope_project_id }).to eq(project.id)
  end

  it 'clears the chip back to the full reach' do
    sign_in admin

    admins_chat = ActsAsTenant.with_tenant(organisation) do
      create(:chat, :org_thread, organisation: organisation, user: admin, scope_project: project)
    end
    patch organisation_assistant_chat_path(organisation, admins_chat),
          params: { chat: { scope_project_id: '' } }

    expect(ActsAsTenant.with_tenant(organisation) { Chat.find(admins_chat.id).scope_project_id }).to be_nil
  end

  # THE invariant of this action. The owner here has the assistant permission but
  # no read access to the project, so it is not on their chip list -- and the
  # write must refuse it rather than store an id whose name they would then see.
  it 'refuses a project the user may not read' do
    sign_in owner

    expect do
      patch organisation_assistant_chat_path(organisation, chat),
            params: { chat: { scope_project_id: project.id } }
    end.not_to(change { stored_scope })

    expect(response).to have_http_status(:redirect).or have_http_status(:unprocessable_content)
  end

  # An empty 422 makes Turbo do nothing at all: the select keeps showing the
  # value that was just refused, and the user gets no sign it did not take. The
  # refusal therefore answers with the SAME stream as the success path, which
  # snaps the chip back to the resolved selection.
  it 'answers a refusal with the chip, not with an empty body' do
    sign_in owner

    patch organisation_assistant_chat_path(organisation, chat),
          params: { chat: { scope_project_id: project.id } },
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("chat_#{chat.id}_scope_row")
  end

  # ⚠️ And it SAYS what happened. The stream above snaps the chip back, which is
  # necessary and was never sufficient: the message sat in the format.html branch
  # alone, which a Turbo submit never reaches, so a refusal answered with exactly
  # the body of a success. The chip flicked back and nothing anywhere said why.
  #
  # It became urgent with step 5b, which offers the write UNPROMPTED: the user
  # clicks a button the app raised by itself, the strip disappears, and silence
  # there is indistinguishable from having worked.
  #
  # Asserted against the project key AND against the absence of the ticket one,
  # because the two refusals are about different things -- one message for both
  # would tell somebody whose ticket was turned away that a PROJECT was
  # unavailable, an answer about the wrong thing.
  it 'says WHY on the Turbo path, not only on the html one' do
    sign_in owner

    patch organisation_assistant_chat_path(organisation, chat),
          params: { chat: { scope_project_id: project.id } },
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

    expect(response.body).to include('target="flash"')
    expect(response.body).to include(ERB::Util.html_escape(I18n.t('flash.assistant_chats.scope_error')))
    expect(response.body).not_to include(ERB::Util.html_escape(I18n.t('flash.assistant_chats.reference_error')))
  end

  # The other half, and the reason the flash is conditional in the template: an
  # accepted change stays quiet. Without this cell the one above would be just as
  # green against a template that raises a banner on every chip change.
  it 'says nothing when the change is accepted' do
    sign_in admin

    admins_chat = ActsAsTenant.with_tenant(organisation) do
      create(:chat, :org_thread, organisation: organisation, user: admin)
    end
    patch organisation_assistant_chat_path(organisation, admins_chat),
          params: { chat: { scope_project_id: project.id } },
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('target="flash"')
  end

  it 'refuses a project from another organisation' do
    other_org = create(:organisation)
    foreign = ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org) }
    sign_in admin

    admins_chat = ActsAsTenant.with_tenant(organisation) do
      create(:chat, :org_thread, organisation: organisation, user: admin)
    end
    patch organisation_assistant_chat_path(organisation, admins_chat),
          params: { chat: { scope_project_id: foreign.id } }

    expect(ActsAsTenant.with_tenant(organisation) { Chat.find(admins_chat.id).scope_project_id }).to be_nil
  end

  # The thread door is the same one every other assistant action uses: a foreign
  # thread answers like a made-up id, never with a different status that would
  # tell an outsider it exists.
  it 'answers a colleague the same 404 as a made-up id' do
    stranger = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: stranger, organisation: organisation, role: assistant_role, active: true)
    end
    sign_in stranger

    patch organisation_assistant_chat_path(organisation, chat), params: { chat: { scope_project_id: '' } }

    expect(response).to have_http_status(:not_found)
  end

  it 'only ever touches the scope column' do
    sign_in admin

    admins_chat = ActsAsTenant.with_tenant(organisation) do
      create(:chat, :org_thread, organisation: organisation, user: admin, title: 'Mein Verlauf')
    end
    patch organisation_assistant_chat_path(organisation, admins_chat),
          params: { chat: { scope_project_id: project.id, title: 'Gekapert', user_id: create(:user).id } }

    reloaded = ActsAsTenant.with_tenant(organisation) { Chat.find(admins_chat.id) }
    expect(reloaded.title).to eq('Mein Verlauf')
    expect(reloaded.user_id).to eq(admin.id)
  end

  # Bezugs-Sammlung S1 (§7.2): the reference left this action. It writes to a
  # COLLECTION now, behind its own routes and its own actors
  # (assistant_chat_references_spec), and what has to hold HERE is that this
  # action does not touch it -- widening the reach is not the same act as dropping
  # the subject of the conversation, and the row re-renders either way, so a
  # silent extra write would only show up in the next answer.
  describe 'the reference collection next door' do
    let(:referenced) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: admin, title: 'Anmeldung')
      end
    end

    let(:admins_chat) do
      ActsAsTenant.with_tenant(organisation) do
        create(:chat, :org_thread, organisation: organisation, user: admin,
                                   scope_project: project, scope_ticket: referenced)
      end
    end

    def reloaded
      ActsAsTenant.with_tenant(organisation) { Chat.find(admins_chat.id) }
    end

    it 'leaves the reference standing when the project chip changes' do
      sign_in admin

      patch organisation_assistant_chat_path(organisation, admins_chat),
            params: { chat: { scope_project_id: '' } }

      expect(reloaded.scope_project_id).to be_nil
      expect(reloaded.scope_references)
        .to eq([Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: referenced.id)])
    end

    # The other direction, and the reason it is worth an example of its own: the
    # collection is no longer reachable from this action at all. A parameter that
    # names it must be ignored, not honoured -- otherwise the split of §7.1 would
    # have left a second door on the old address.
    it 'ignores a reference parameter smuggled into this action' do
      sign_in admin
      other = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: admin, title: 'Zweites')
      end

      patch organisation_assistant_chat_path(organisation, admins_chat),
            params: { chat: { scope_references: [{ type: 'Ticket', id: other.id }] } }

      expect(reloaded.scope_references)
        .to eq([Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: referenced.id)])
    end

    # S2 (§8.1): both actions answer with the SAME template, and only one of them
    # is a reference write. The scope chip has nothing to do with the collection,
    # so it must not unfold it -- otherwise every change of "Sucht in" would open
    # a list the user had deliberately collapsed.
    it 'leaves the reference list collapsed, because this is not a reference write' do
      sign_in admin
      second = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: admin, title: 'Zweites')
      end
      ActsAsTenant.with_tenant(organisation) do
        admins_chat.update_column(:scope_references, [referenced, second].map do |ticket|
          Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: ticket.id)
        end)
      end

      patch organisation_assistant_chat_path(organisation, admins_chat),
            params: { chat: { scope_project_id: '' } },
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response.body).to include('<details')
      expect(response.body).not_to match(/<details[^>]*\sopen[\s>=]/)
    end
  end
end
