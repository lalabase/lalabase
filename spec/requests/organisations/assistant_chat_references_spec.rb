# frozen_string_literal: true

require 'rails_helper'

# Bezugs-Sammlung S1 (§7.1): the write path of the reference collection. The read
# side lives in Tools::Scope (scope_spec) and can only ever narrow; what has to
# hold HERE is that nothing the asker may not read ever gets stored, and that the
# two idempotent cases (adding twice, removing what is gone) are answered as
# successes rather than as two extra shapes of failure.
#
# Why storing matters even though the reach is intersected anyway: a stored entry
# is also what the chip PRINTS. A ticket title is exactly what this app withholds
# from someone without access, so accepting an arbitrary id would turn a filter
# into a way to read one.
RSpec.describe 'Assistant chat references (Bezugs-Sammlung S1)', type: :request do
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

  # Has the assistant permission and NO read access to the project below, which
  # is what makes the refusals here refusals about rights and not about tenancy.
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

  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: admin, title: 'Anmeldung')
    end
  end

  # The owner's own thread, used for every refusal: `owner` may use the assistant
  # and may not read the project.
  let(:owners_chat) do
    ActsAsTenant.with_tenant(organisation) { create(:chat, :org_thread, organisation: organisation, user: owner) }
  end

  def admins_chat(**attrs)
    ActsAsTenant.with_tenant(organisation) do
      create(:chat, :org_thread, organisation: organisation, user: admin, **attrs)
    end
  end

  def reload(chat)
    ActsAsTenant.with_tenant(organisation) { Chat.find(chat.id) }
  end

  def key_for(record)
    Assistant::ReferenceRegistry.key_of(record)
  end

  def stored(record)
    Assistant::ReferenceRegistry.stored_entry(type: record.class.name, id: record.id)
  end

  def post_reference(chat, key)
    post organisation_assistant_chat_references_path(organisation, chat), params: { key: key }
  end

  def delete_reference(chat, key)
    delete organisation_assistant_chat_reference_path(organisation, chat, key)
  end

  # A collection of n, built through the REAL write path now that the limit is 10
  # -- update_column would bypass the very rule these cells are about.
  #
  # ⚠️ Prosopite counts per EXAMPLE, not per request, so n identical "load the
  # user, the tenant, the chat" triples read exactly like an N+1 to it. Paused for
  # the SETUP only, and every cell below then makes exactly ONE measured request,
  # which is this file's implicit rule anyway -- so the write path keeps its
  # query guard where it matters. (Inside the example body, never in an `around`:
  # the suite's `before(:each) { Prosopite.scan }` would undo that.)
  def chat_referencing(count, chat: admins_chat)
    where = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Zweitprojekt') }
    tickets = ActsAsTenant.with_tenant(organisation) do
      Array.new(count) do |i|
        create(:ticket, project: where, organisation: organisation, creator: admin, title: "Aufgabe #{i}")
      end
    end
    Prosopite.pause
    tickets.each { |record| post_reference(chat, key_for(record)) }
    Prosopite.resume
    [chat.reload, tickets]
  end

  def chat_referencing_two
    chat_referencing(2)
  end

  def chat_at_the_limit
    chat_referencing(Assistant::ReferenceRegistry::MAX_REFERENCES)
  end

  describe 'POST' do
    it 'stores a reference to an object the user may read' do
      sign_in admin
      chat = admins_chat

      post_reference(chat, key_for(ticket))

      expect(reload(chat).scope_references).to eq([stored(ticket)])
    end

    # ⚠️ E3, and the half a user actually FEELS: setting a reference no longer
    # touches the scope chip. Until S2 it wrote the object's project into it, so
    # somebody who had deliberately pinned "Sucht in" to their project had that
    # choice silently overwritten by a click on "Assistent" in a ticket of another
    # one -- and cleared again by the x. The narrowing was never asked for; it was
    # a side effect of a button that says something else.
    #
    # Both directions in one example, because "does not write it" is true of a
    # route that writes nothing at all: the collection lands, the chip does not
    # move.
    it 'leaves the scope chip exactly where the user put it' do
      sign_in admin
      elsewhere = ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation, name: 'Kundenportal v2')
      end
      chat = admins_chat(scope_project: elsewhere)

      post_reference(chat, key_for(ticket))

      expect(reload(chat).scope_references).to eq([stored(ticket)])
      expect(reload(chat).scope_project_id).to eq(elsewhere.id)
    end

    # ...and it does not INVENT one either. A thread searching everything keeps
    # searching everything.
    it 'sets no project where the user had chosen none' do
      sign_in admin
      chat = admins_chat

      post_reference(chat, key_for(ticket))

      expect(reload(chat).scope_project_id).to be_nil
    end

    # T-9 (plan §12), and it REPLACES what T-15 said. While MAX_REFERENCES was 1,
    # a POST onto a full list overwrote the standing entry -- deliberate throwaway
    # code, so that "Bezug wechseln zu" (which the app offers unprompted) would not
    # run into a 422 in a slice that was meant to change nothing. With a limit of
    # 10 that trade is gone: adding is adding, and the eleventh is refused.
    #
    # ⚠️ Refused OUT LOUD. A limit that swallows the click silently is the worst
    # of the three options -- the chip row comes back looking exactly as it did,
    # and the user clicks again.
    it 'refuses the eleventh, says so, and leaves the ten standing' do
      sign_in admin
      chat, full = chat_at_the_limit
      eleventh = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: admin, title: 'Der elfte')
      end

      post organisation_assistant_chat_references_path(organisation, chat),
           params: { key: key_for(eleventh) },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(ERB::Util.html_escape(I18n.t('flash.assistant_chats.reference_limit',
                                                                    count: Assistant::ReferenceRegistry::MAX_REFERENCES)))
      expect(reload(chat).scope_references).to eq(full.map { |record| stored(record) })
    end

    # The n-1 half of the boundary, and the interesting one: a limit that is off
    # by one refuses the TENTH, and every other cell in this file is green on
    # nine. Its own example because the refusal above is its own request -- see
    # the note on chat_referencing.
    it 'still takes the tenth' do
      sign_in admin
      chat, nine = chat_referencing(Assistant::ReferenceRegistry::MAX_REFERENCES - 1)
      tenth = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: admin, title: 'Der zehnte')
      end

      post_reference(chat, key_for(tenth))

      expect(reload(chat).scope_references).to eq((nine + [tenth]).map { |record| stored(record) })
    end

    # ⚠️ A duplicate stays SUCCESS at the limit. It changes nothing, so refusing it
    # would answer "you already have this" with "you have too many" -- and the
    # offer strip would then treat a reference that already stands as a rejection.
    # ⚠️ On the TURBO path, and that is not a detail. `:ok .or :redirect` would
    # make success and refusal indistinguishable here -- the refusal answers the
    # HTML path with a 302, so the disjunction is green either way. Measured: with
    # the duplicate short circuit removed this cell stayed green until it asked
    # for the stream. (Same finding the S1 review already made about two other
    # cells in this file.)
    it 'still answers a duplicate with success when the list is full' do
      sign_in admin
      chat, full = chat_at_the_limit

      post organisation_assistant_chat_references_path(organisation, chat),
           params: { key: key_for(full.first) },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('target="flash"')
      expect(reload(chat).scope_references).to eq(full.map { |record| stored(record) })
    end

    # Order is ADD order (plan §4.1), and the limit must not quietly reshuffle it.
    # Measured: an implementation that appends and then takes `.last(MAX)` keeps
    # the order but drops the OLDEST silently -- which is what the S1 throwaway
    # did, and it is exactly what "refuse" replaces.
    it 'keeps the entries in the order they were added' do
      sign_in admin
      chat, three = chat_referencing(3)

      expect(reload(chat).scope_references).to eq(three.map { |record| stored(record) })
    end

    # T-10 (plan §12), first half: adding what is already there is SUCCESS and
    # changes NOTHING -- not the answer shape and not the order. Re-appending
    # would move the entry, which the prompt and the collapsed summary read as a
    # different collection.
    #
    # ⚠️ Asked on the TURBO path, like every other "this is success" cell in this
    # file. A refusal answers the HTML path with a 302, so `:ok .or :redirect`
    # cannot tell the two apart -- measured on the duplicate cell further down,
    # which stayed green with the short circuit removed until it asked for the
    # stream and for the absence of a flash.
    it 'answers a second identical add with success and an unchanged list' do
      sign_in admin
      chat = admins_chat(scope_ticket: ticket)

      expect do
        post organisation_assistant_chat_references_path(organisation, chat),
             params: { key: key_for(ticket) },
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      end.not_to(change { reload(chat).scope_references })

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('target="flash"')
    end

    # The mass-assignment half, carried over from the PATCH action this write left
    # (assistant_chat_scope_spec "writes only the field it was given"): the route
    # takes ONE parameter, and anything else riding along in the body is not a
    # write. Title and owner are the two that would matter.
    it 'writes the collection and nothing else' do
      sign_in admin
      chat = admins_chat(title: 'Mein Verlauf')

      post organisation_assistant_chat_references_path(organisation, chat),
           params: { key: key_for(ticket), chat: { title: 'Gekapert', user_id: create(:user).id } }

      expect(reload(chat).scope_references).to eq([stored(ticket)])
      expect(reload(chat).title).to eq('Mein Verlauf')
      expect(reload(chat).user_id).to eq(admin.id)
    end

    # THE invariant of this action. `owner` has the assistant permission but no
    # read access to the project, so the ticket is not theirs to reference.
    # Storing the id would be storing a name they may not see.
    it 'refuses an object the user may not read, and stores nothing' do
      sign_in owner
      chat = owners_chat

      expect { post_reference(chat, key_for(ticket)) }.not_to(change { reload(chat).scope_references })
    end

    # ⚠️ What refuses here is the project clause (a foreign ticket lives in a
    # foreign project) and, under the tenant a request runs in, acts_as_tenant.
    # The organisation clause of the registry lambda is isolated only in
    # spec/models/chat_spec.rb ("refuses a row of another organisation even when
    # its project is reachable here"), WITHOUT an ambient tenant; a request spec
    # cannot take that role.
    it 'refuses an object of another organisation' do
      other_org = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other_org) do
        create(:ticket, project: create(:project, organisation: other_org), organisation: other_org,
                        creator: create(:user), title: 'Fremd')
      end
      sign_in admin
      chat = admins_chat(scope_ticket: ticket)

      post_reference(chat, key_for(foreign))

      expect(reload(chat).scope_references).to eq([stored(ticket)])
    end

    # The knowledge objects (doc/assistent_wissen_kontext_plan.md, step 1),
    # through the SAME write path. What has to hold is the per-type gate: a
    # note resolves through the notes area, and a ticket right does not open it.
    describe 'knowledge objects and meetings' do
      let(:meeting) do
        ActsAsTenant.with_tenant(organisation) do
          create(:meeting, project: project, organisation: organisation, creator: admin, title: 'Planungsrunde')
        end
      end
      let(:note) do
        ActsAsTenant.with_tenant(organisation) do
          create(:note, project: project, organisation: organisation, creator: admin, title: 'Einarbeitung')
        end
      end
      let(:document) do
        ActsAsTenant.with_tenant(organisation) do
          document = create(:document, project: project, organisation: organisation, creator: admin)
          version = create(:document_version, document: document, organisation: organisation, title: 'Angebot')
          document.update!(current_version: version)
          document
        end
      end

      # On the TURBO path for the body (the HTML path answers with a redirect),
      # and the second add is the measured one: the row it sends back has to
      # carry all three keys, which is what the offer strip reads.
      it 'stores both next to a ticket, in the order they were added' do
        sign_in admin
        chat = admins_chat(scope_ticket: ticket)

        Prosopite.pause
        post_reference(chat, key_for(note))
        Prosopite.resume
        post organisation_assistant_chat_references_path(organisation, chat),
             params: { key: key_for(document) },
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(reload(chat).scope_references).to eq([stored(ticket), stored(note), stored(document)])
        expect(response.body).to include(key_for(ticket), key_for(note), key_for(document))
      end

      it 'adds a meeting to mixed references without changing the search project or search opt-in, and removes just that meeting' do
        sign_in admin
        records = [ticket, note, document]
        chat = admins_chat(scope_references: records.map { |record| stored(record) }, scope_project: project)

        post organisation_assistant_chat_references_path(organisation, chat),
             params: { key: key_for(meeting) }, as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(reload(chat).scope_references).to eq((records + [meeting]).map { |record| stored(record) })
        expect(response.body).to include(key_for(meeting), 'Planungsrunde')
        expect(reload(chat).scope_project_id).to eq(project.id)
        expect(meeting.reload.create_embeddings).to be false

        delete_reference(chat, key_for(meeting))

        expect(reload(chat).scope_references).to eq(records.map { |record| stored(record) })
      end

      it 'refuses a meeting once the mixed collection reaches ten references' do
        sign_in admin
        chat, = chat_at_the_limit

        expect { post_reference(chat, key_for(meeting)) }.not_to(change { reload(chat).scope_references })
        expect(flash[:alert]).to eq(I18n.t('flash.assistant_chats.reference_limit', count: 10))
      end

      it 'rejects a meeting without meeting rights even with ticket rights' do
        create(:project_permission, user: owner, project: project, tickets_access: 'read_only')
        sign_in owner

        post organisation_assistant_chat_references_path(organisation, owners_chat),
             params: { key: key_for(meeting) }, as: :turbo_stream

        expect(response).to have_http_status(:unprocessable_content)
        expect(reload(owners_chat).scope_references).to eq([])
        expect(response.body).not_to include('Planungsrunde')
      end

      it 'accepts a meeting with read-only meeting permission' do
        create(:project_permission, user: owner, project: project, meetings_access: 'read_only')
        sign_in owner

        post_reference(owners_chat, key_for(meeting))

        expect(reload(owners_chat).scope_references).to eq([stored(meeting)])
      end

      # Refused on the TURBO path with the flash, and nothing stored. The title
      # must not leak either: a refusal that names its subject discloses it.
      it 'keeps the areas apart: a ticket right does not let a note in' do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_permission, user: owner, project: project, tickets_access: 'read_only')
        end
        sign_in owner

        post organisation_assistant_chat_references_path(organisation, owners_chat),
             params: { key: key_for(note) },
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response.body).to include(ERB::Util.html_escape(I18n.t('flash.assistant_chats.reference_error')))
        expect(reload(owners_chat).scope_references).to eq([])
        expect(response.body).not_to include('Einarbeitung')
      end

      it 'lets the note in once the notes area is readable' do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_permission, user: owner, project: project, notes_access: 'read_only')
        end
        sign_in owner

        post_reference(owners_chat, key_for(note))

        expect(reload(owners_chat).scope_references).to eq([stored(note)])
      end
    end

    # An id that is not a UUID must answer like any other unreachable object, not
    # crash: ActiveRecord would cast it to NULL and the resolver would land on IS
    # NULL, so the key parser refuses it before a query is ever built.
    it 'refuses a key whose id is not a UUID' do
      sign_in admin
      chat = admins_chat(scope_ticket: ticket)

      post_reference(chat, 'Ticket:nicht-mal-eine-uuid')

      # The redirect alone says nothing: the accepted write redirects too. The
      # alert is what only a refusal carries.
      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('flash.assistant_chats.reference_error'))
      expect(reload(chat).scope_references).to eq([stored(ticket)])
    end

    # Fail-closed on the TYPE, and ⚠️ without ever constantizing it: a key names a
    # type by looking it up in the registry, so an unknown one is simply not a
    # reference. Nothing here turns a parameter into a class.
    it 'refuses a key naming a type the registry does not know' do
      sign_in admin
      chat = admins_chat

      post_reference(chat, "Organisation:#{organisation.id}")

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('flash.assistant_chats.reference_error'))
      expect(reload(chat).scope_references).to eq([])
    end

    it 'refuses a key that is not a key at all' do
      sign_in admin
      chat = admins_chat

      post_reference(chat, 'kaputt')

      expect(reload(chat).scope_references).to eq([])
    end

    # A refusal answers with the ROW, like every other refusal on these surfaces:
    # an empty 422 leaves the chip showing what was just refused with nothing to
    # say it did not take, and this arrives without anybody crafting it (a project
    # archived between the render and the click lands here).
    it 'answers a refusal with the row, not with an empty body' do
      sign_in owner
      chat = owners_chat

      post organisation_assistant_chat_references_path(organisation, chat),
           params: { key: key_for(ticket) },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("chat_#{chat.id}_scope_row")
    end

    # ⚠️ And it SAYS so, on the TURBO path. The message used to sit in the
    # format.html branch alone, which a Turbo submit never reaches, so a refusal
    # answered with exactly the body of a success: the chip snapped back and
    # nothing anywhere said why. The offer of step 5b clicks straight into this.
    #
    # Asserted against the reference key AND against the absence of the project
    # one, because the two refusals are about different things.
    it 'says WHY, and says it about the reference rather than about a project' do
      sign_in owner
      chat = owners_chat

      post organisation_assistant_chat_references_path(organisation, chat),
           params: { key: key_for(ticket) },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response.body).to include('target="flash"')
      expect(response.body).to include(ERB::Util.html_escape(I18n.t('flash.assistant_chats.reference_error')))
      expect(response.body).not_to include(ERB::Util.html_escape(I18n.t('flash.assistant_chats.scope_error')))
    end

    # The other half, and the reason the flash is conditional in the template: an
    # accepted write stays quiet. Without this cell the one above would be just as
    # green against a template that raises a banner on every change.
    it 'says nothing when the write is accepted' do
      sign_in admin
      chat = admins_chat

      post organisation_assistant_chat_references_path(organisation, chat),
           params: { key: key_for(ticket) },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('target="flash"')
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

      post_reference(admins_chat, key_for(ticket))

      expect(response).to have_http_status(:not_found)
    end

    # The policy door behind the thread door: ChatPolicy#update? also asks
    # assistant_usable?, so the OWNER of a thread is refused once their role lacks
    # use_assistant. The 404 cell above cannot see this gate (the stranger never
    # reaches it), and without this cell both `authorize` lines could go.
    it 'refuses the owner once their role lacks use_assistant' do
      plain = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, organisation: organisation, title: 'Plain', is_default: true)
        create(:membership, user: plain, organisation: organisation, role: role, active: true)
      end
      chat = ActsAsTenant.with_tenant(organisation) do
        create(:chat, :org_thread, organisation: organisation, user: plain)
      end
      sign_in plain

      expect { post_reference(chat, key_for(ticket)) }.not_to(change { reload(chat).scope_references })
      expect(flash[:alert]).to be_present
    end

    # Review of this slice, same finding as #639 on the meeting analyses: in
    # production BaseActor turns an unexpected exception into a failure result
    # whose only error is the RAW exception text, and a lock timeout's text
    # carries the SQL. The controller masks :internal_error like
    # MeetingAnalysesController and TimeSessionGroupsController do.
    it 'never surfaces an unexpected exception message' do
      sign_in admin
      chat = admins_chat
      raw = 'PG::LockNotAvailable: ERROR: canceling statement due to lock timeout ' \
            'SELECT "chats".* FROM "chats" WHERE "chats"."id" = $1 LIMIT $2 FOR UPDATE'
      allow(Actors::AddChatReference).to receive(:call)
        .and_return(Actors::BaseActor::Result.new(success: false, errors: [raw], code: :internal_error))

      post organisation_assistant_chat_references_path(organisation, chat),
           params: { key: key_for(ticket) },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include('FOR UPDATE')
      expect(response.body).to include(ERB::Util.html_escape(I18n.t('flash.assistant_chats.reference_error')))
    end

    # ⚠️ A refusal is rendered from the PERSISTED state. update! assigns before
    # it validates, and a failed save leaves the assigned values on the record;
    # a row drawn from that record showed the NEW chip next to the refusal, and
    # the panel read the changed keys as a landed write. Reachable without a
    # crafted request: an operator retires the thread's persona, and every
    # save on that thread fails prompt_persona_available from then on.
    it 'shows a refused addition as NOT landed when the thread cannot be saved' do
      sign_in admin
      persona = create(:prompt_persona)
      chat = admins_chat(prompt_persona: persona)
      persona.update!(active: false)

      post organisation_assistant_chat_references_path(organisation, chat),
           params: { key: key_for(ticket) },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(reload(chat).scope_references).to eq([])
      expect(response.body).not_to include("Ticket:#{ticket.id}")
      expect(response.body).to include('target="flash"')
    end

    # ONE Tools::Scope per write. The reach is not a lookup (active_member?, the
    # admin short circuit, the global-permission check, a pluck), it is memoised
    # per instance, and it runs under the row lock: the actor hands the instance
    # that resolved the addition to the normaliser instead of letting it build a
    # second one.
    it 'resolves the asker\'s reach once per write' do
      sign_in admin
      chat = admins_chat
      allow(Chats::ReferenceNormalizer).to receive(:call).and_call_original

      post_reference(chat, key_for(ticket))

      expect(reload(chat).scope_references).to eq([stored(ticket)])
      expect(Chats::ReferenceNormalizer).to have_received(:call)
        .with(hash_including(scope: an_instance_of(Lalabase::Tools::Scope)))
    end

    # §8.1: the disclosure state is DOM state and this response REPLACES the whole
    # row, so what the server renders is the state afterwards. A reference write
    # leaves the list open -- the cross of every entry sits inside it, and a list
    # that snaps shut after each write makes removing three entries a seven-click
    # affair.
    #
    # A duplicate add on purpose: it is the one accepted POST that leaves a
    # two-entry collection standing while MAX_REFERENCES is still one.
    it 'sends the row back with the list open' do
      sign_in admin
      chat, tickets = chat_referencing_two

      post organisation_assistant_chat_references_path(organisation, chat),
           params: { key: key_for(tickets.first) },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<details')
      expect(response.body).to match(/<details[^>]*\sopen[\s>=]/)
    end

    # And a REFUSAL too. The row is redrawn either way, the user was working in
    # the open list, and closing it under them would make the refusal look like a
    # second thing that happened.
    it 'sends the row back open when it refuses' do
      sign_in admin
      chat, = chat_referencing_two
      unreadable = ActsAsTenant.with_tenant(organisation) do
        other = create(:organisation)
        ActsAsTenant.with_tenant(other) do
          create(:ticket, project: create(:project, organisation: other), organisation: other, creator: create(:user))
        end
      end

      post organisation_assistant_chat_references_path(organisation, chat),
           params: { key: key_for(unreadable) },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to match(/<details[^>]*\sopen[\s>=]/)
    end

    # ⚠️ C (review of #642). ARCHIVING A PROJECT IS REVERSIBLE, deleting references
    # is not. The normaliser prunes to what resolves right now, and resolution runs
    # over `projects.active` -- so an admin archiving a project in the morning plus
    # ANY write in the afternoon erased every reference from it, permanently.
    # Un-archiving does not bring them back.
    #
    # At MAX_REFERENCES 1 that cost one entry and was visible. At 10 it can quietly
    # take nine, and the duplicate path is the quietest of all: the app answers
    # "success, nothing changed" while deleting what the user cannot see.
    #
    # The pruning now lives in ONE place -- adding at the limit, where the user has
    # asked for room. Everywhere else the stored list is left alone; the READ path
    # already drops what does not resolve, which is what reference_normalizer's own
    # header argues about: the display, not the column.
    it 'writes nothing at all for a duplicate, so unresolvable entries survive' do
      sign_in admin
      elsewhere = ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation, name: 'Wird archiviert')
      end
      in_archived = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: elsewhere, organisation: organisation, creator: admin, title: 'Ueberlebt')
      end
      chat = admins_chat
      ActsAsTenant.with_tenant(organisation) do
        chat.update!(scope_references: [in_archived, ticket].map { |record| stored(record) })
        elsewhere.update!(archived_at: Time.current)
      end

      post_reference(chat, key_for(ticket))

      expect(reload(chat).scope_references).to eq([stored(in_archived), stored(ticket)])
    end

    # ⚠️ And the MOST ordinary write of all, which the two cells above still left
    # open: adding a THIRD object while two stand and eight slots are free. Nobody
    # is full, nobody asked for room -- and the normaliser ran here anyway, so the
    # reference from the archived project was gone, permanently, because somebody
    # clicked "Assistent" on an unrelated ticket. The comment above #next_list
    # already promised the opposite ("Adding at the limit is the ONE moment"); the
    # code did not keep it.
    #
    # The limit still counts what RESOLVES (§7.2), so dead entries never block a
    # slot. Only the PRUNING is tied to the moment room is actually needed.
    it 'leaves an unresolvable entry standing when another is added below the limit' do
      sign_in admin
      elsewhere = ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation, name: 'Wird archiviert')
      end
      in_archived = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: elsewhere, organisation: organisation, creator: admin, title: 'Ueberlebt')
      end
      newcomer = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: admin, title: 'Nachzuegler')
      end
      chat = admins_chat
      ActsAsTenant.with_tenant(organisation) do
        chat.update!(scope_references: [in_archived, ticket].map { |record| stored(record) })
        elsewhere.update!(archived_at: Time.current)
      end

      post_reference(chat, key_for(newcomer))

      expect(reload(chat).scope_references)
        .to eq([stored(in_archived), stored(ticket), stored(newcomer)])
    end
  end

  describe 'DELETE' do
    # The other half of C: removing ONE entry must not take the invisible ones with
    # it. Same construction, and the one a user actually walks into -- the cross on
    # a chip is the most ordinary write there is.
    it 'keeps references from an archived project when another one is removed' do
      sign_in admin
      elsewhere = ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation, name: 'Wird archiviert')
      end
      in_archived = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: elsewhere, organisation: organisation, creator: admin, title: 'Ueberlebt')
      end
      chat = admins_chat
      ActsAsTenant.with_tenant(organisation) do
        chat.update!(scope_references: [in_archived, ticket].map { |record| stored(record) })
        elsewhere.update!(archived_at: Time.current)
      end

      delete_reference(chat, key_for(ticket))

      expect(reload(chat).scope_references).to eq([stored(in_archived)])
    end

    it 'takes the named entry back out' do
      sign_in admin
      chat = admins_chat(scope_ticket: ticket, scope_project: project)

      delete_reference(chat, key_for(ticket))

      expect(reload(chat).scope_references).to eq([])
    end

    # ⚠️ E3, the mirror image of the POST cell: removing the last reference no
    # longer clears the scope chip. It used to, because the reference had SET it;
    # now the chip is the user's own and nobody else writes it. Clearing it here
    # would throw away a choice this route never made.
    it 'leaves the scope chip alone when the last reference goes' do
      sign_in admin
      chat = admins_chat(scope_ticket: ticket, scope_project: project)

      delete_reference(chat, key_for(ticket))

      expect(reload(chat).scope_references).to eq([])
      expect(reload(chat).scope_project_id).to eq(project.id)
    end

    # "Writes only what it was asked about", carried over from
    # assistant_chat_scope_spec ":225". Since E3 the project is never this route's
    # business at all, which makes the rule easier to hold and no less worth
    # pinning: a removal that removes nothing must not touch a thing.
    it 'leaves the project alone when the removal changes nothing' do
      sign_in admin
      chat = admins_chat(scope_ticket: ticket, scope_project: project)

      delete_reference(chat, "Ticket:#{SecureRandom.uuid}")

      expect(reload(chat).scope_project_id).to eq(project.id)
      expect(reload(chat).scope_references).to eq([stored(ticket)])
    end

    # T-10 (plan §12), second half. A key that names nothing, a key for something
    # already gone, a second click on the same cross: all SUCCESS. A second answer
    # shape for "was gone already" would be a case distinction with no use -- the
    # caller wanted it gone and it is gone.
    # ⚠️ Both on the TURBO path, for the reason spelled out at the duplicate add:
    # a refusal redirects, so `:ok .or :redirect` is green for success AND for
    # refusal, which is exactly the distinction these two cells exist to make.
    it 'answers an unknown key with success, and changes nothing' do
      sign_in admin
      chat = admins_chat(scope_ticket: ticket)

      expect do
        delete organisation_assistant_chat_reference_path(organisation, chat, "Ticket:#{SecureRandom.uuid}"),
               headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      end.not_to(change { reload(chat).scope_references })

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('target="flash"')
    end

    it 'answers a key that is not a key at all with success' do
      sign_in admin
      chat = admins_chat(scope_ticket: ticket)

      expect do
        delete organisation_assistant_chat_reference_path(organisation, chat, 'kaputt'),
               headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      end.not_to(change { reload(chat).scope_references })

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('target="flash"')
    end

    # The mass-assignment half on this side too: the route takes its key from the
    # URL segment and nothing from the body. Same claim as on the POST, and worth
    # its own cell because the two actions are two implementations.
    it 'writes the collection and nothing else' do
      sign_in admin
      chat = admins_chat(scope_ticket: ticket, scope_project: project, title: 'Mein Verlauf')

      delete organisation_assistant_chat_reference_path(organisation, chat, key_for(ticket)),
             params: { chat: { title: 'Gekapert', user_id: create(:user).id } }

      expect(reload(chat).scope_references).to eq([])
      expect(reload(chat).title).to eq('Mein Verlauf')
      expect(reload(chat).user_id).to eq(admin.id)
    end

    # ⚠️ This example used to claim the OPPOSITE, and the correction is the point of
    # C (review of #642). It said a dead entry "goes at the next write -- any write",
    # and that made a REVERSIBLE admin action (archiving a project) irreversible for
    # everyone's references, through the most ordinary write there is.
    #
    # The rule now: a removal removes what it names, and nothing else. Not resolving
    # already means leaving no trace where it counts -- no chip, no key, no line in
    # the prompt -- and that is a READ-path property. Deleting the column entry is
    # reserved for the one moment the user asks for room (Actors::AddChatReference
    # at the limit).
    it 'leaves an entry that stopped resolving alone when the request names another' do
      sign_in admin
      chat = admins_chat(scope_ticket: ticket)
      ActsAsTenant.with_tenant(organisation) { project.update!(archived_at: Time.current) }

      delete_reference(chat, "Ticket:#{SecureRandom.uuid}")

      expect(reload(chat).scope_references).to eq([stored(ticket)])
    end

    # ...and the half that keeps "it blocks no slot" true. Room is made at the
    # moment room is needed, not before, and un-archiving up to that point still
    # brings everything back.
    it 'makes room from dead entries when the collection is full and one is added' do
      sign_in admin
      chat, full = chat_at_the_limit
      ActsAsTenant.with_tenant(organisation) do
        Project.find(full.first.project_id).update!(archived_at: Time.current)
      end
      newcomer = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: admin, title: 'Nachzuegler')
      end

      post_reference(chat, key_for(newcomer))

      expect(reload(chat).scope_references.last).to eq(stored(newcomer))
      expect(reload(chat).scope_references.size).to be <= Assistant::ReferenceRegistry::MAX_REFERENCES
    end

    it 'answers a colleague the same 404 as a made-up id' do
      stranger = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: stranger, organisation: organisation, role: assistant_role, active: true)
      end
      sign_in stranger

      delete_reference(admins_chat(scope_ticket: ticket), key_for(ticket))

      expect(response).to have_http_status(:not_found)
    end

    # Same policy door as on the POST, and its own cell because the two actions
    # are two implementations.
    it 'refuses the owner once their role lacks use_assistant' do
      plain = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, organisation: organisation, title: 'Plain', is_default: true)
        create(:membership, user: plain, organisation: organisation, role: role, active: true)
      end
      chat = ActsAsTenant.with_tenant(organisation) do
        create(:chat, :org_thread, organisation: organisation, user: plain, scope_ticket: ticket)
      end
      sign_in plain

      expect { delete_reference(chat, key_for(ticket)) }.not_to(change { reload(chat).scope_references })
      expect(flash[:alert]).to be_present
    end

    # The mirror case of "leaves the project alone when the removal changes
    # nothing", found in review: a removal that removes nothing because the list
    # was ALREADY empty (a stale chip in a second tab) must leave a project alone
    # that the user chose through the scope chip after the reference was gone.
    # The actor used to clear the project whenever the list came out empty,
    # whether or not this write had emptied it.
    it 'leaves a project alone that was chosen after the reference was already gone' do
      sign_in admin
      chat = admins_chat(scope_project: project)

      delete_reference(chat, key_for(ticket))

      expect(reload(chat).scope_project_id).to eq(project.id)
      expect(reload(chat).scope_references).to eq([])
    end

    # ⚠️ The destroy action used to discard the actor's result and draw the row
    # from the record the actor had assigned to: a removal the thread could not
    # SAVE showed the chip gone while the database kept the reference -- a
    # failure indistinguishable from success, and the thread could never lose
    # its reference again. Same construction as on the POST: a retired persona.
    it 'refuses a removal the thread cannot save, and keeps the chip on screen' do
      sign_in admin
      persona = create(:prompt_persona)
      chat = admins_chat(scope_ticket: ticket, prompt_persona: persona)
      persona.update!(active: false)

      delete organisation_assistant_chat_reference_path(organisation, chat, key_for(ticket)),
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(reload(chat).scope_references).to eq([stored(ticket)])
      expect(response.body).to include("Ticket:#{ticket.id}")
      expect(response.body).to include('target="flash"')
    end

    it 'never surfaces an unexpected exception message' do
      sign_in admin
      chat = admins_chat(scope_ticket: ticket)
      allow(Actors::RemoveChatReference).to receive(:call)
        .and_return(Actors::BaseActor::Result.new(success: false, errors: ['PG::LockNotAvailable: ... FOR UPDATE'],
                                                  code: :internal_error))

      delete organisation_assistant_chat_reference_path(organisation, chat, key_for(ticket)),
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include('FOR UPDATE')
      expect(response.body).to include(ERB::Util.html_escape(I18n.t('flash.assistant_chats.reference_error')))
    end

    # The half that matters most for the open state: the cross lives INSIDE the
    # open list, so a row that comes back closed after a removal costs a click
    # before every further one. Removing an unknown key is the documented
    # success that leaves a two-entry collection standing under MAX_REFERENCES 1.
    it 'sends the row back with the list open' do
      sign_in admin
      chat, = chat_referencing_two

      delete organisation_assistant_chat_reference_path(organisation, chat, "Ticket:#{SecureRandom.uuid}"),
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to match(/<details[^>]*\sopen[\s>=]/)
    end
  end
end
