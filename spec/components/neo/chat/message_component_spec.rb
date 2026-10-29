# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Neo::Chat::MessageComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user)         { create(:user, organisation: organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  # `user` OWNS the thread: since projekt_chat_abbau the owner short-circuit is the
  # only way a bubble renders unredacted, so a spec about anything else (links, the
  # copy button, coverage notices) has to render for the owner or it measures the
  # redaction instead of its subject. Examples that are ABOUT a non-owner build their
  # own viewer.
  let(:chat)         { create(:chat, organisation: organisation, user: user) }
  let(:chatpost)     { chat.chatposts.first }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def render_with(**opts)
    render_inline(described_class.new(chatpost: chatpost, **opts))
  end

  describe 'basic rendering' do
    it 'renders the chatpost content' do
      chatpost.update!(content: 'Hello world')
      render_with
      expect(rendered_content).to include('Hello world')
    end

    it 'uses a stable dom id derived from the chatpost' do
      render_with
      expect(page).to have_css("##{ActionView::RecordIdentifier.dom_id(chatpost)}")
    end

    # 2026-08-28: the author line is gone from both roles. It named the only two
    # people who can ever appear in this log, once every three lines. The
    # surface says which is which now (question = right-aligned bubble, answer =
    # plain prose), so these two cells are inverted on purpose: they used to pin
    # the labels being there.
    it 'does not name the asker' do
      chatpost.update!(user: user)
      allow(user).to receive(:full_name).and_return('Alice Anderson')
      render_with
      expect(rendered_content).not_to include('Alice Anderson')
    end

    it 'does not label the answer as coming from an assistant' do
      assistant_post = chat.chatposts.create!(organisation: organisation, role: 'assistant',
                                              content: 'AI says hi')
      render_inline(described_class.new(chatpost: assistant_post))
      expect(rendered_content).to include('AI says hi')
      expect(rendered_content).not_to match(/AI Assistant/i)
    end
  end

  # The shape of the transcript (2026-08-28 feedback + screenshot): a question is
  # a tinted bubble at the right edge, an answer is plain prose across the full
  # column. These cells pin the DIFFERENCE between the two, which is the whole
  # point of dropping the author line.
  describe 'question and answer are told apart by surface' do
    it 'pushes a question to the right edge and gives it the bubble surface' do
      chatpost.update!(content: 'Wie viele Tickets?')
      render_with
      expect(page).to have_css('.flex.justify-end .bg-surface-shell.rounded-2xl',
                               text: 'Wie viele Tickets?')
    end

    it 'leaves an answer as plain prose, neither aligned right nor tinted' do
      answer = chat.chatposts.create!(organisation: organisation, role: 'assistant',
                                      content: 'Acht offene.')
      render_inline(described_class.new(chatpost: answer))
      expect(rendered_content).to include('Acht offene.')
      # The row the PROSE sits in, not the page: the hover row above every message
      # is right-aligned for both roles and would answer a page-wide query.
      body = page.find('.prose')
      expect(body[:class]).not_to include('bg-surface-shell')
      expect(body.find(:xpath, '..')[:class]).not_to include('justify-end')
    end

    # ⚠️ The width cap is a left inset, NOT a max-width: the bubble carries
    # `prose` + `max-w-none`, and a competing max-width utility on the same
    # element would be decided by Tailwind's emission order rather than by intent.
    # A cell here because the next reader's instinct will be to "simplify" it.
    it 'caps the bubble width with an inset rather than a second max-width' do
      render_with
      row = page.find('.ps-\\[20\\%\\]')
      # Scoped to the row and its bubble, NOT the page: a page-wide negative would
      # also fire for an arbitrary max-width in a child component that has nothing
      # to do with this cap.
      expect(row[:class]).not_to include('max-w-[')
      expect(row.find('.prose')[:class]).not_to include('max-w-[')
    end
  end

  describe 'delete button visibility (defense in depth on permissions)' do
    def stub_helpers(write_access:)
      fake_policy  = double('ProjectPolicy', area_access?: write_access)
      fake_helpers = double('helpers').as_null_object
      allow(fake_helpers).to receive(:policy).and_return(fake_policy)
      allow(fake_helpers).to receive(:organisation_assistant_chat_chatpost_path).and_return('/cp-del-path')
      allow_any_instance_of(described_class).to receive(:helpers).and_return(fake_helpers)
    end

    it 'is hidden when show_delete: false (default)' do
      render_with
      expect(page).not_to have_css('[data-turbo-method="delete"]')
    end

    it 'is hidden when show_delete: true but no current_user given' do
      render_with(show_delete: true, current_organisation: organisation)
      expect(page).not_to have_css('[data-turbo-method="delete"]')
    end

    it 'is hidden when show_delete: true but no current_organisation given' do
      render_with(show_delete: true, current_user: user)
      expect(page).not_to have_css('[data-turbo-method="delete"]')
    end

    it 'is hidden when chatpost is the first message (is_first?)' do
      allow(chatpost).to receive(:is_first?).and_return(true)
      allow(chatpost).to receive(:is_destroyable?).and_return(true)
      render_with(show_delete: true, current_user: user, current_organisation: organisation)
      expect(page).not_to have_css('[data-turbo-method="delete"]')
    end

    it 'is hidden when chatpost.is_destroyable? returns false' do
      allow(chatpost).to receive(:is_destroyable?).and_return(false)
      render_with(show_delete: true, current_user: user, current_organisation: organisation)
      expect(page).not_to have_css('[data-turbo-method="delete"]')
    end

    it 'is hidden when show_delete is false (the container denied chats:write) even though destroyable + not first' do
      # show_delete IS the write-access verdict now — the container computes it
      # once from the policy and passes it down; this component no longer
      # re-derives the policy per bubble. A false flag must hide the button.
      allow(chatpost).to receive(:is_destroyable?).and_return(true)
      allow(chatpost).to receive(:is_first?).and_return(false)
      render_with(show_delete: false, current_user: user, current_organisation: organisation)
      expect(page).not_to have_css('[data-turbo-method="delete"]')
    end

    it 'is SHOWN when all conditions are met (positive path)' do
      allow(chatpost).to receive(:is_destroyable?).and_return(true)
      allow(chatpost).to receive(:is_first?).and_return(false)
      stub_helpers(write_access: true)
      render_with(show_delete: true, current_user: user, current_organisation: organisation)
      expect(page).to have_css('a[data-turbo-method="delete"]')
    end

    # The WIRING of the reveal, which is all this level can see. The behaviour
    # itself moved to hover_reveal_controller.js, and the rule it enforces
    # ("never two rows at once") is pinned in spec/javascript/lib/hover_reveal.test.js.
    #
    # ⚠️ This used to assert a class chain (`can-hover:group-hover:opacity-100`),
    # and that chain is the defect (29.08.2026). Every row decided for itself, so
    # nothing held the "at most one" rule: measured from a screen recording in
    # Safari, rows switched on as the pointer passed and then stayed, seven lit at
    # once, until a resize cleared five of them in one frame. A cell that asserts
    # the chain is a cell that asks for the bug back.
    it 'wires the action row to the hover-reveal owner instead of a hover class chain' do
      allow(chatpost).to receive(:is_destroyable?).and_return(true)
      allow(chatpost).to receive(:is_first?).and_return(false)
      stub_helpers(write_access: true)
      render_with(show_delete: true, current_user: user, current_organisation: organisation)

      row = page.find('a[data-turbo-method="delete"]').ancestor('div[data-hover-reveal-target="actions"]')
      expect(row[:class]).not_to include('group-hover')
      expect(row[:class]).not_to include('opacity-0')
      expect(row[:class]).not_to include('focus-within')
    end

    # The message is the ROW the owner marks. Without this attribute the actions
    # node is inside no row at all, rowFrom returns null, and nothing ever reveals.
    it 'marks the message itself as the row the pointer can be on' do
      render_with

      expect(page).to have_css('[data-chat-role][data-hover-reveal-target="row"]')
    end

    # `group` was the anchor of the old chain and has no other job on this element.
    # Left behind it would quietly re-arm any group-hover utility added later.
    it 'drops the group anchor the old chain hung on' do
      render_with

      expect(page.find('[data-chat-role]')[:class]).not_to include('group')
    end

    it 'uses the chatpost-specific delete path (not the chat path)' do
      allow(chatpost).to receive(:is_destroyable?).and_return(true)
      allow(chatpost).to receive(:is_first?).and_return(false)
      fake_helpers = double('helpers').as_null_object
      allow(fake_helpers).to receive(:policy).and_return(double(area_access?: true))
      # IDs, not records, and no project segment: the assistant route is
      # /org/:id/assistant_chats/:chat_id/chatposts/:id.
      expect(fake_helpers).to receive(:organisation_assistant_chat_chatpost_path)
        .with(chatpost.organisation_id, chatpost.chat_id, chatpost.id)
        .and_return('/cp-del-path')
      allow_any_instance_of(described_class).to receive(:helpers).and_return(fake_helpers)
      render_with(show_delete: true, current_user: user, current_organisation: organisation)
      expect(page).to have_css('a[href="/cp-del-path"]')
    end
  end

  describe 'content sanitization (XSS protection)' do
    # If anyone replaces `<%= sanitize(@chatpost.content) %>` with `<%= raw(...) %>`
    # or just `<%= @chatpost.content.html_safe %>`, this test fires.
    it 'strips script tags from chatpost content (executable XSS path is closed)' do
      chatpost.update!(content: "<script>alert('xss')</script>Hello")
      render_with
      expect(rendered_content).not_to include('<script>')
      expect(rendered_content).not_to include('</script>')
      expect(rendered_content).to include('Hello')
    end

    it 'strips iframe / object / embed (additional XSS vectors)' do
      chatpost.update!(content: '<iframe src="evil.html"></iframe>safe')
      render_with
      expect(rendered_content).not_to include('<iframe')
      expect(rendered_content).to include('safe')
    end

    describe 'explicit allowlist (audit fix #10 — img/table/svg/style are not in default chat needs)' do
      it 'strips <img> tags entirely (tracking-pixel + exfil vector)' do
        chatpost.update!(content: '<p>safe</p><img src="https://tracker/pixel.png">')
        render_with
        expect(rendered_content).not_to include('<img')
        expect(rendered_content).to include('safe')
      end

      it 'strips <table> tags (not part of chat content surface)' do
        chatpost.update!(content: '<table><tr><td>cell</td></tr></table>')
        render_with
        expect(rendered_content).not_to include('<table')
        expect(rendered_content).not_to include('<td')
      end

      it 'strips <svg> tags (XSS-prone via onload + javascript: hrefs)' do
        chatpost.update!(content: '<svg onload="alert(1)"></svg>safe')
        render_with
        expect(rendered_content).not_to include('<svg')
        expect(rendered_content).to include('safe')
      end

      it 'strips <style> tags (CSS-injection vector)' do
        chatpost.update!(content: '<style>body{display:none}</style>safe')
        render_with
        expect(rendered_content).not_to include('<style')
        expect(rendered_content).to include('safe')
      end

      # Content is now Markdown: it is rendered to HTML and THEN sanitised. Raw
      # HTML in the source is stripped at render time (filter_html), so the only
      # way to get tags is via Markdown syntax — which is exactly the point.
      it 'renders Markdown emphasis, inline code and fenced code blocks' do
        chatpost.update!(content: "**bold** _i_ `c`\n\n```\np\n```")
        render_with
        expect(rendered_content).to include('<strong>bold</strong>')
        expect(rendered_content).to include('<em>i</em>')
        expect(rendered_content).to include('<code>c</code>')
        expect(rendered_content).to include('<pre>')
      end

      it 'renders Markdown headings as <h*>, not literal ## text' do
        chatpost.update!(content: "## Title\n\nbody")
        render_with
        expect(rendered_content).to include('<h2>Title</h2>')
        expect(rendered_content).not_to include('## Title')
      end

      it 'renders Markdown lists as <ul><li>' do
        chatpost.update!(content: "- one\n- two")
        render_with
        expect(rendered_content).to include('<ul>')
        expect(rendered_content).to include('<li>one</li>')
      end

      it 'renders Markdown links with safe hrefs and strips javascript: links' do
        chatpost.update!(content: '[good](https://ok.com) [bad](javascript:alert)')
        render_with
        expect(rendered_content).to include('href="https://ok.com"')
        expect(rendered_content).not_to include('javascript:')
      end

      it 'strips raw HTML from the SOURCE — no tags/handlers can be injected via Markdown' do
        chatpost.update!(content: '<span onclick="evil()" title="ok">text</span>')
        render_with
        expect(rendered_content).not_to include('onclick')
        expect(rendered_content).to include('<p>text</p>') # span stripped, plain text remains
      end
    end

    describe 'allowlist constants locked as contract' do
      it { expect(described_class::ALLOWED_TAGS).to be_frozen }
      it { expect(described_class::ALLOWED_ATTRIBUTES).to be_frozen }
      it { expect(described_class::ALLOWED_TAGS).to include('p', 'strong', 'em', 'code', 'a') }
      it { expect(described_class::ALLOWED_TAGS).not_to include('img', 'table', 'svg', 'script', 'iframe', 'style') }
      it { expect(described_class::ALLOWED_ATTRIBUTES).to include('href') }
      it { expect(described_class::ALLOWED_ATTRIBUTES).not_to include('onclick', 'onload', 'onerror', 'style') }
    end
  end

  describe 'time_ago' do
    it 'is omitted entirely when created_at is nil' do
      allow(chatpost).to receive(:created_at).and_return(nil)
      render_with
      # the time-ago key in DE is "vor %{time}" — the word "vor " or " ago" must not appear
      expect(rendered_content).not_to match(/\bvor\s+\S/)
      expect(rendered_content).not_to match(/\bago\b/)
    end

    # 2026-08-28: the minutes only matter at the moment you are reaching for the
    # trash, so they live INSIDE the hover-revealed row rather than on a standing
    # line of their own. The cell pins the containment, not the classes: a time
    # that drifts back out of that row is the regression.
    it 'sits inside the hover-revealed row, not on a standing line' do
      render_with
      expect(page).to have_css('[data-hover-reveal-target="actions"]', text: /vor\s+\S/)
    end

    it 'still renders the row for a message that has no trash and no regenerate' do
      # No current_user/organisation -> no trash, and a question has no
      # regenerate. The copy button is still there, so this is not the empty-row
      # case; what it pins is that the time survives WITHOUT the trash, which is
      # the message the first post of every thread is.
      render_with
      expect(page).to have_no_css('[data-turbo-method="delete"]')
      expect(page).to have_css('[data-hover-reveal-target="actions"]', text: /vor\s+\S/)
    end
  end

  describe 'citation list visibility per role (M8.1 regression)' do
    let(:citation_payload) { [{ 'type' => 'vision', 'id' => 'v1' }] }

    it 'renders the citation list for assistant chatposts' do
      # Bypass set_initial_role callback that re-flips the first chatpost to
      # role='system' on save.
      chatpost.update_columns(role: 'assistant', source_citations: citation_payload)
      render_with
      expect(rendered_content).to include(I18n.t('views.organisations.chats.citations.vision'))
    end

    it 'does NOT render citations for user chatposts even if source_citations is set' do
      # Citations are semantically only valid on assistant messages. A bug
      # populating user.source_citations must not surface them in the UI.
      chatpost.update_columns(role: 'user', source_citations: citation_payload)
      render_with
      expect(rendered_content).not_to include(I18n.t('views.organisations.chats.citations.header'))
    end

    it 'does NOT render citations for system-flagged chatposts even if source_citations is set' do
      chatpost.update_columns(role: 'system', source_citations: citation_payload)
      render_with
      expect(rendered_content).not_to include(I18n.t('views.organisations.chats.citations.header'))
    end
  end

  describe 'regenerate action' do
    # A completed assistant answer = content present AND model_used set (the
    # ChatResponseJob folded final write). That is the only state offering the
    # regenerate action. (2026-07-19: this replaced four style pills — the style
    # itself now lives in the pills under the composer, StyleControlComponent.)
    def completed_assistant(content: 'Done', model_used: 'gpt-x')
      chat.chatposts.create!(organisation: organisation, role: 'assistant', content: content, model_used: model_used)
    end

    describe '#show_regenerate? / #answer_complete?' do
      it 'is true for a completed assistant answer (content + model_used)' do
        expect(described_class.new(chatpost: completed_assistant).show_regenerate?).to be(true)
      end

      it 'is false while streaming (model_used not set yet)' do
        post = completed_assistant(content: 'partial…', model_used: nil)
        expect(described_class.new(chatpost: post).show_regenerate?).to be(false)
        expect(described_class.new(chatpost: post).answer_pending?).to be(true)
      end

      it 'is false for an empty placeholder bubble' do
        post = completed_assistant(content: '', model_used: nil)
        expect(described_class.new(chatpost: post).show_regenerate?).to be(false)
      end

      it 'is false for an error message (content present, but never completed → no model_used)' do
        post = completed_assistant(content: 'Service unavailable', model_used: nil)
        post.update!(analysis_context: { 'provenance' => [] })
        expect(described_class.new(chatpost: post).show_regenerate?).to be(false)
        expect(described_class.new(chatpost: post).answer_pending?).to be(false)
      end

      it 'is false for a blank-but-complete bubble (pins the content.present? clause)' do
        # model_used set but content empty — the ONLY test where dropping
        # `content.present?` from show_regenerate? would otherwise wrongly show it.
        post = completed_assistant(content: '', model_used: 'gpt-x')
        expect(described_class.new(chatpost: post).show_regenerate?).to be(false)
      end

      it 'is false for the system-flagged first message' do
        expect(described_class.new(chatpost: chatpost).show_regenerate?).to be(false)
      end
    end

    describe 'rendering' do
      def stub_regenerate_helpers
        fake = double('helpers').as_null_object
        allow(fake).to receive(:regenerate_organisation_assistant_chat_chatpost_path).and_return('/regenerate-path')
        allow(fake).to receive(:protect_against_forgery?).and_return(false)
        allow_any_instance_of(described_class).to receive(:helpers).and_return(fake)
      end

      it 'renders a single labelled regenerate button when complete' do
        stub_regenerate_helpers
        render_inline(described_class.new(chatpost: completed_assistant))

        expect(page).to have_button(I18n.t('views.organisations.chats.message.regenerate'), count: 1)
      end

      # The style is NOT chosen here any more: a mutation re-adding per-style
      # buttons (kürzer/einfacher/…) alongside the action would resurrect the
      # two-places-to-set-style split this redesign removed.
      it 'renders NO per-style buttons alongside it' do
        stub_regenerate_helpers
        render_inline(described_class.new(chatpost: completed_assistant))

        # Exactly one form in the message: the regenerate action. The four style
        # button_to forms would each add one.
        expect(page).to have_css('form', count: 1)
        expect(page).not_to have_css('[data-controller="chat-regenerate"]')
      end

      it 'renders NO regenerate action while the answer is still streaming' do
        stub_regenerate_helpers
        render_inline(described_class.new(chatpost: completed_assistant(content: 'partial…', model_used: nil)))

        expect(page).not_to have_button(I18n.t('views.organisations.chats.message.regenerate'))
      end
    end
  end

  # Render gate (Plan §4.4): The viewer sees the answer text ONLY if they may read every
  # area touched by the content (from the citations) — otherwise a redaction placeholder
  # (all-or-nothing) and hiding of the foreign citation. The check happens at DISPLAY TIME, i.e.
  # against the viewer's current_user (not the asker's) — this also protects members added
  # only later. Fail-closed without a current_user (broadcast).
  # Copy the message text (2026-08-28 feedback: asking the same question again
  # should not mean re-typing it). Offered on both roles, because the trash next
  # to it is, and because copying an answer into a ticket is the same move.
  describe 'copy affordance' do
    def stub_delete_helpers
      fake_helpers = double('helpers').as_null_object
      allow(fake_helpers).to receive(:policy).and_return(double(area_access?: true))
      allow(fake_helpers).to receive(:organisation_assistant_chat_chatpost_path).and_return('/cp-del-path')
      allow_any_instance_of(described_class).to receive(:helpers).and_return(fake_helpers)
    end

    it 'offers a copy button on a question' do
      chatpost.update!(content: 'wieviel offene tickets im projekt calc')
      render_with
      expect(page).to have_css('button[data-clipboard-target="button"]')
    end

    it 'offers a copy button on an answer' do
      answer = chat.chatposts.create!(organisation: organisation, role: 'assistant',
                                      content: 'Acht offene.', model_used: 'gpt-x')
      render_inline(described_class.new(chatpost: answer))
      expect(page).to have_css('button[data-clipboard-target="button"]')
    end

    # The controller reads the RENDERED text, so the source target has to sit on
    # the message body. Without it the button is wired to nothing and copies an
    # empty string, silently.
    it 'points the clipboard at the message body' do
      chatpost.update!(content: 'wieviel offene tickets im projekt calc')
      render_with
      expect(page).to have_css('[data-clipboard-target="source"]',
                               text: 'wieviel offene tickets im projekt calc')
    end

    it 'is left of the trash, which is what makes re-asking the cheap move' do
      chatpost.update!(content: 'Frage')
      allow(chatpost).to receive(:is_destroyable?).and_return(true)
      allow(chatpost).to receive(:is_first?).and_return(false)
      stub_delete_helpers
      render_with(show_delete: true, current_user: user, current_organisation: organisation)

      row = page.find('a[data-turbo-method="delete"]').ancestor('div[data-hover-reveal-target="actions"]')
      order = row.all('button[data-clipboard-target="button"], a[data-turbo-method="delete"]')
      expect(order.length).to eq(2)
      expect(order.first.tag_name).to eq('button')
    end

    # ⚠️ REGRESSION GUARD for the whole point of L7. #coverage_notice exists as a
    # sentence rather than a chip because "the chip is not there any more once
    # this answer is copied into a ticket", and the in-app help promises the
    # scope survives the copy ("Das bleibt auch dann noch unter der Antwort, wenn
    # du sie später woandershin kopierst", 15-ai/09-assistant.md). A clipboard
    # source that stops at the prose hands over a narrowed answer that reads like
    # a complete one, which is the one failure L7 was built to prevent. The
    # sources ride along for the same reason.
    it 'copies the coverage notice and the sources with the answer, not the prose alone' do
      owner = create(:user)
      create(:membership, user: owner, organisation: organisation,
                          role: create(:role, organisation: organisation, is_default: true), active: true)
      org_chat = create(:chat, :org_thread, user: owner)
      answer = org_chat.chatposts.create!(
        organisation: organisation, role: 'assistant',
        content: 'Acht offene Tickets.', model_used: 'gpt-x',
        source_coverage: { 'chosen' => 'Nordlicht' },
        source_citations: [{ 'type' => 'vision', 'id' => 'v1' }]
      )
      render_inline(described_class.new(chatpost: answer, current_user: owner,
                                        current_organisation: organisation))

      copied = page.find('[data-clipboard-target="source"]')
      expect(copied).to have_text('Acht offene Tickets.')
      expect(copied).to have_css('[data-testid="coverage-notice"]',
                                 text: I18n.t('views.organisations.chats.message.coverage_notice_chosen',
                                              project: 'Nordlicht'))
      expect(copied).to have_css('[data-testid="citation-list"]')
    end

    it 'is absent while the answer bubble is still empty' do
      placeholder = chat.chatposts.create!(organisation: organisation, role: 'assistant', content: '')
      render_inline(described_class.new(chatpost: placeholder))
      expect(page).to have_no_css('button[data-clipboard-target="button"]')
    end

    # SECURITY: the same rule regenerate stands on. A viewer who may not read the
    # answer must not be handed a copy of it either -- the prose is not on the
    # page for them, but a copy button wired to a source that is not there is one
    # refactor away from being wired to one that is.
    it 'is absent on a redacted answer' do
      standard_role = create(:role, title: 'Standard User', organisation: organisation, is_default: true)
      gated = chat.chatposts.create!(
        organisation: organisation, role: 'assistant',
        content: 'Der Stand zu Thema X ist geklaert.', model_used: 'gpt-x',
        source_citations: [{ 'type' => 'ticket', 'area' => 'tickets', 'id' => SecureRandom.uuid,
                             'project_id' => project.id, 'number' => 42, 'title' => 'GeheimerTitel' }]
      )
      blind = create(:user)
      create(:membership, user: blind, organisation: organisation, role: standard_role, active: true)
      create(:project_permission, user: blind, project: project, tickets_access: 'no_access')

      render_inline(described_class.new(chatpost: gated, current_user: blind,
                                        current_organisation: organisation))
      expect(rendered_content).to include(I18n.t('views.organisations.chats.message.redacted'))
      expect(page).to have_no_css('button[data-clipboard-target="button"]')
    end
  end

  # ⚠️ projekt_chat_abbau changed what this gate can decide, and it changed it in the
  # SAFE direction. It used to be a per-area question: a viewer with tickets-read saw a
  # ticket-sourced answer, a viewer without it got the redaction. That question was asked
  # of ProjectPolicy about the THREAD'S project, and no thread has one any more, so
  # #area_allowed? is false for everybody (which is what ProjectPolicy already answered
  # for a nil record).
  #
  # The gate therefore has exactly two outcomes now:
  #
  #   owner of the thread            -> sees everything (owner_viewer? short-circuit)
  #   anyone else, broadcast included -> redacted, whatever their project rights are
  #
  # ...unless the answer cites no CONTENT at all: sourced_areas empty means nothing to
  # redact, and a code-only answer stays readable. That is the one differentiator left,
  # and it is the one worth keeping examples for.
  #
  # This is defense in depth, not the gate that matters: ChatPolicy::Scope is owner-only,
  # so a non-owner never reaches a bubble in the first place. The per-area matrix that
  # used to live here (tickets, notes, documents, documentation, each in both directions)
  # is gone with its subject. If a shared surface ever comes back, the matrix comes back
  # WITH it -- and the line to change is #area_allowed?, which is why it survived as a
  # method rather than being inlined into a `false`.
  describe 'render-gate / audience (Plan §4.4)' do
    let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

    let(:ticket_answer) do
      chat.chatposts.create!(
        organisation: organisation, role: 'assistant',
        content: 'Der Stand zu Thema X ist geklaert.', model_used: 'gpt-x',
        source_citations: [{ 'type' => 'ticket', 'area' => 'tickets', 'id' => SecureRandom.uuid,
                             'project_id' => project.id, 'number' => 42, 'title' => 'GeheimerTitel' }]
      )
    end

    def viewer(**areas)
      u = create(:user)
      create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
      create(:project_permission, { user: u, project: project }.merge(areas))
      u
    end

    def render_for(viewer_user, post: ticket_answer)
      render_inline(described_class.new(chatpost: post, current_user: viewer_user,
                                        current_organisation: organisation))
    end

    it 'shows the full answer to the OWNER of the thread' do
      render_for(chat.user)

      expect(rendered_content).to include('Der Stand zu Thema X')
      expect(rendered_content).to include('GeheimerTitel')
    end

    # THE assertion of the cut in this file, and it is a strengthening: full read access
    # to every sourced area no longer buys a non-owner anything.
    it 'redacts for a non-owner even with read access to every sourced area' do
      render_for(viewer(tickets_access: 'read_only'))

      expect(rendered_content).not_to include('Der Stand zu Thema X')
      expect(rendered_content).to include(I18n.t('views.organisations.chats.message.redacted'))
      expect(rendered_content).not_to include('GeheimerTitel')
    end

    it 'redacts for a non-owner without the area either (unchanged, and now for two reasons)' do
      render_for(viewer(tickets_access: 'no_access'))

      expect(rendered_content).not_to include('Der Stand zu Thema X')
      expect(rendered_content).to include(I18n.t('views.organisations.chats.message.redacted'))
    end

    it 'fail-closed: redacts a content-bearing answer when there is no current_user (broadcast)' do
      render_inline(described_class.new(chatpost: ticket_answer))

      expect(rendered_content).not_to include('Der Stand zu Thema X')
      expect(rendered_content).to include(I18n.t('views.organisations.chats.message.redacted'))
    end

    # The remaining differentiator, and the reason #redacted? still asks anything at all:
    # an answer that cites no content area has nothing to redact, so it stays readable
    # even for a non-owner. Code citations carry no area on purpose.
    it 'does NOT redact a code-only answer for a non-owner (sourced_areas empty)' do
      code_only = chat.chatposts.create!(
        organisation: organisation, role: 'assistant', content: 'Die Methode liegt in Bar#baz.',
        model_used: 'gpt-x',
        source_citations: [{ 'type' => 'symbol', 'id' => SecureRandom.uuid, 'qualified_name' => 'Bar#baz' }]
      )
      render_for(viewer(tickets_access: 'no_access'), post: code_only)

      expect(rendered_content).to include('Die Methode liegt in Bar#baz')
      expect(rendered_content).not_to include(I18n.t('views.organisations.chats.message.redacted'))
    end

    it 'hides the regenerate action on a redacted answer' do
      # Security: a viewer who may not READ the answer must not be able to re-run it
      # either. This gate lives here (not server-side behind a resolved target), which
      # is why the action stayed on the message.
      render_for(viewer(tickets_access: 'no_access'))

      expect(page).not_to have_button(I18n.t('views.organisations.chats.message.regenerate'))
    end

    it 'derives sourced_areas as Symbols, not JSONB Strings (pins the R2 .to_sym contract)' do
      # area_access? coerced via normalize_area, so dropping .to_sym was harmless TODAY —
      # the documented Symbol contract would otherwise be untested. Kept through the cut
      # because it describes the SHAPE the gate reads, not the verdict it reaches.
      component = described_class.new(chatpost: ticket_answer)

      expect(component.send(:sourced_areas)).to eq([:tickets])
    end

    # The CitationList renders at role==assistant, INDEPENDENT of the redacted?-branch
    # (template Z.40-46) → visible_citations is the SOLE defence for citations on a
    # redacted answer. A code citation (no area) must stay visible (chat-wide context);
    # the content citation must vanish.
    it 'on a redacted answer KEEPS the code citation (no area) while dropping the content one' do
      mixed = chat.chatposts.create!(
        organisation: organisation, role: 'assistant', content: 'Stand.', model_used: 'gpt-x',
        source_citations: [
          { 'type' => 'ticket', 'area' => 'tickets', 'id' => SecureRandom.uuid,
            'project_id' => project.id, 'number' => 9, 'title' => 'GeheimesTicket' },
          { 'type' => 'symbol', 'id' => SecureRandom.uuid, 'qualified_name' => 'Bar#baz' }
        ]
      )
      render_for(viewer(tickets_access: 'read_only'), post: mixed)

      expect(rendered_content).to include('Bar#baz')            # code citation survives
      expect(rendered_content).not_to include('GeheimesTicket') # content citation dropped
    end

    it 'fail-closed broadcast (no current_user): hides the content citation title, keeps the code citation' do
      mixed = chat.chatposts.create!(
        organisation: organisation, role: 'assistant', content: 'Stand.', model_used: 'gpt-x',
        source_citations: [
          { 'type' => 'ticket', 'area' => 'tickets', 'id' => SecureRandom.uuid,
            'project_id' => project.id, 'number' => 3, 'title' => 'TitelLeak' },
          { 'type' => 'symbol', 'id' => SecureRandom.uuid, 'qualified_name' => 'Code#here' }
        ]
      )
      render_inline(described_class.new(chatpost: mixed)) # current_user nil → broadcast

      expect(rendered_content).not_to include('TitelLeak')
      expect(rendered_content).to include('Code#here')
    end

    it 'renders the shield-lock placeholder and NO prose block when redacted' do
      render_for(viewer(tickets_access: 'no_access'))

      expect(page).to have_css('[data-testid="redacted-notice"] .bi-shield-lock')
      expect(page).not_to have_css('.prose')
    end

    # People S3: an answer drawn on the people directory carries the people area. The
    # citation comes from the producer itself (Citations.person), so the gate reads what the
    # tools emit: without the area the answer would count as content-free and reach every
    # reader, the broadcast included. The asker sees it, nobody else, not even someone who
    # may open the directory.
    describe 'an answer about a person of the people directory (People S3)' do
      let(:person) { create(:person, organisation: organisation, name: 'Doris Dienstleister', phone: '+49 30 1234567') }
      let(:person_answer) do
        entry = People::Directory::Entry.new(kind: :contact, user: nil, person: person)
        chat.chatposts.create!(
          organisation: organisation, role: 'assistant', model_used: 'gpt-x',
          content: 'Doris Dienstleister erreichst du unter +49 30 1234567.',
          source_citations: [Lalabase::Citations.person(entry).deep_stringify_keys]
        )
      end

      def directory_reader
        role = create(:role, organisation: organisation)
        create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)
        reader = create(:user)
        create(:membership, user: reader, organisation: organisation, role: role, active: true)
        reader
      end

      it 'shows the answer and its person to the owner of the thread' do
        render_for(chat.user, post: person_answer)

        expect(rendered_content).to include('+49 30 1234567')
        expect(rendered_content).to include('Person: Doris Dienstleister')
      end

      it 'redacts it for a non-owner, even one who may open the directory' do
        render_for(directory_reader, post: person_answer)

        expect(rendered_content).to include(I18n.t('views.organisations.chats.message.redacted'))
        expect(rendered_content).not_to include('+49 30 1234567')
        expect(rendered_content).not_to include('Doris Dienstleister')
      end

      it 'redacts it in the broadcast, which renders without a viewer' do
        render_inline(described_class.new(chatpost: person_answer))

        expect(rendered_content).to include(I18n.t('views.organisations.chats.message.redacted'))
        expect(rendered_content).not_to include('+49 30 1234567')
        expect(rendered_content).not_to include('Doris Dienstleister')
      end
    end
  end

  # Source attribution (chat_quellen_attribution_plan.md §6.3/§7). Slice 1 wires the
  # render-strip and the used-flag ANZEIGE filter; the security gate is unchanged (its
  # invariant lives in citation_gate_full_list_guard_spec). Both stay inert until the
  # mechanism is live — legacy citations carry no flag, and no marker exists yet.
  describe 'source attribution — used-flag filter (§7)' do
    def assistant_with(citations)
      chat.chatposts.create!(organisation: organisation, role: 'assistant', content: 'Antwort',
                             model_used: 'gpt-x', source_citations: citations)
    end

    it 'keeps a used:true citation and drops a used:false one (used-filter AFTER the area gate)' do
      post = assistant_with([
                              { 'type' => 'vision', 'id' => 'v1', 'used' => true },
                              { 'type' => 'capability', 'id' => 'c1', 'name' => 'Notifications', 'used' => false }
                            ])
      component = described_class.new(chatpost: post, current_user: user, current_organisation: organisation)
      expect(component.visible_citations.map { |c| c['type'] }).to eq(['vision'])
    end

    it 'shows a legacy citation with NO used key (pre-attribution answers keep all sources)' do
      post = assistant_with([{ 'type' => 'vision', 'id' => 'v1' }]) # no 'used' key
      component = described_class.new(chatpost: post, current_user: user, current_organisation: organisation)
      expect(component.visible_citations.map { |c| c['type'] }).to eq(['vision'])
    end

    it 'renders NO citation list when every citation is used:false (the sources line disappears)' do
      post = assistant_with([{ 'type' => 'vision', 'id' => 'v1', 'used' => false }])
      render_inline(described_class.new(chatpost: post, current_user: user, current_organisation: organisation))
      expect(rendered_content).not_to include(I18n.t('views.organisations.chats.citations.header'))
      expect(rendered_content).not_to include(I18n.t('views.organisations.chats.citations.vision'))
    end

    it 'applies the used-filter UNDER the area gate — a forbidden area is dropped even when used:true' do
      # The area gate is the OUTER filter: a used:true citation the viewer may NOT read
      # stays hidden (security wins over the attribution flag).
      role = create(:role, title: 'Standard User', organisation: organisation, is_default: true)
      no_ticket = create(:user)
      create(:membership, user: no_ticket, organisation: organisation, role: role, active: true)
      create(:project_permission, user: no_ticket, project: project, tickets_access: 'no_access')
      post = assistant_with([{ 'type' => 'ticket', 'area' => 'tickets', 'id' => SecureRandom.uuid,
                               'project_id' => project.id, 'number' => 1, 'title' => 'Secret', 'used' => true }])
      component = described_class.new(chatpost: post, current_user: no_ticket, current_organisation: organisation)
      expect(component.visible_citations).to eq([])
    end
  end

  describe 'source attribution — render-strip (§6.3)' do
    it 'strips a trailing complete marker before rendering the bubble' do
      chatpost.update_columns(role: 'assistant', content: "Die Antwort steht.\n\n[[used_sources: 1, 3]]")
      render_with
      expect(rendered_content).to include('Die Antwort steht.')
      expect(rendered_content).not_to include('used_sources')
    end

    it 'strips a partially-streamed marker at the end (kills the mid-stream flash)' do
      chatpost.update_columns(role: 'assistant', content: 'Noch beim Tippen [[used_sources: 1,')
      render_with
      expect(rendered_content).to include('Noch beim Tippen')
      expect(rendered_content).not_to include('used_sources')
    end

    it 'strips a malformed marker the parser rejects (P2: strip is decoupled from parse)' do
      chatpost.update_columns(role: 'assistant', content: "Antwort.\n\n[[used_sources: 1 and 3]]")
      render_with
      expect(rendered_content).to include('Antwort.')
      expect(rendered_content).not_to include('used_sources')
    end
  end

  # ===========================================================================
  # S3a R-H2: the owner of a personal thread is NEVER redacted
  # ===========================================================================
  #
  # An org-wide answer carries area citations but no project; the old gate asks
  # ProjectPolicy.new(user, nil) and fails closed -- redacting the answer for its
  # OWN owner. The owner short-circuit is the formal version of plan §6.2's "his
  # case no longer arises": retrieval was gated against the asker, and the asker
  # is the only reader.
  describe 'owner short-circuit (S3a, R-H2)' do
    let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }
    let(:owner) do
      u = create(:user)
      create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
      u
    end
    let(:org_thread) { create(:chat, :org_thread, organisation: organisation, user: owner) }
    let(:org_answer) do
      org_thread.chatposts.create!(
        organisation: organisation, role: 'assistant',
        content: 'Du hast 12 unabgerechnete Stunden.', model_used: 'gpt-x',
        source_citations: [{ 'type' => 'time_report', 'area' => 'time_sessions',
                             'id' => 'p:abc', 'title' => 'Zeiten', 'filters' => {} }]
      )
    end

    def render_org_answer(viewer)
      render_inline(described_class.new(chatpost: org_answer, current_user: viewer,
                                        current_organisation: organisation))
    end

    it 'shows the owner their own org-wide answer despite the area citation' do
      render_org_answer(owner)

      expect(rendered_content).to include('12 unabgerechnete Stunden')
      expect(rendered_content).not_to include(I18n.t('views.organisations.chats.message.redacted'))
    end

    it 'keeps the citation list visible for the owner' do
      render_org_answer(owner)

      expect(rendered_content).to include(I18n.t('views.organisations.chats.citations.header'))
    end

    it 'stays fail-closed on the viewer-agnostic broadcast render (no current_user)' do
      render_org_answer(nil)

      expect(rendered_content).to include(I18n.t('views.organisations.chats.message.redacted'))
    end

    it 'redacts for a non-owner viewer (defense in depth below the policy)' do
      other = create(:user)
      create(:membership, user: other, organisation: organisation, role: standard_role, active: true)
      render_org_answer(other)

      expect(rendered_content).to include(I18n.t('views.organisations.chats.message.redacted'))
    end

    # Was: "keeps the area gate on a personal PROJECT thread even for its owner".
    # That kind of thread is gone (projekt_chat_abbau), and with it the reason the
    # short-circuit was narrowed to org-wide threads in the T2 second review: a project
    # thread's retrieval was gated per QUESTION and legacy pre-S1 answers had been
    # fetched under a colleague's rights. Every thread is owner-only and single-asker
    # now, so the short-circuit is simply the rule. What replaces the example is the
    # opposite pin, one line up: a NON-owner is redacted no matter what they may read.
  end

  # S3a T3 (L7): a narrowed answer names its reach — rendered DETERMINISTICALLY
  # from the persisted contract field, never from the model's prose. The plan's
  # mutation probe is the two-value comparison below: change the field, the
  # notice must change with it.
  describe 'coverage notice (L7)' do
    let(:owner) do
      u = create(:user)
      create(:membership, user: u, organisation: organisation,
                          role: create(:role, organisation: organisation, is_default: true), active: true)
      u
    end
    let(:org_chat) { create(:chat, :org_thread, user: owner) }

    def render_answer(coverage)
      answer = org_chat.chatposts.create!(
        organisation: organisation, role: 'assistant',
        content: 'Antwort mit Zahlen.', model_used: 'gpt-x',
        source_coverage: coverage
      )
      render_inline(described_class.new(chatpost: answer,
                                        current_user: owner, current_organisation: organisation))
      rendered_content
    end

    it 'names a narrowed reach with the numbers from the contract field' do
      out = render_answer('searched' => 3, 'total' => 12)

      expect(out).to include(
        I18n.t('views.organisations.chats.message.coverage_notice', searched: 3, total: 12)
      )
    end

    # The SAME chatpost rendered twice with a changed field: two different posts
    # would differ in dom_id anyway and prove nothing about the notice.
    it 'changes with the field (deterministic source, the plan mutation probe)' do
      answer = org_chat.chatposts.create!(
        organisation: organisation, role: 'assistant', content: 'Antwort mit Zahlen.', model_used: 'gpt-x',
        source_coverage: { 'searched' => 3, 'total' => 12 }
      )
      notice = ->(n) { I18n.t('views.organisations.chats.message.coverage_notice', searched: n, total: 12) }

      render_inline(described_class.new(chatpost: answer, current_user: owner, current_organisation: organisation))
      expect(rendered_content).to include(notice.call(3))

      answer.update_columns(source_coverage: { 'searched' => 5, 'total' => 12 })
      render_inline(described_class.new(chatpost: answer.reload, current_user: owner,
                                        current_organisation: organisation))
      expect(rendered_content).to include(notice.call(5))
      expect(rendered_content).not_to include(notice.call(3))
    end

    it 'stays silent when nothing was narrowed' do
      out = render_answer('searched' => 12, 'total' => 12)

      expect(out).not_to include(I18n.t('views.organisations.chats.message.coverage_notice',
                                        searched: 12, total: 12))
    end

    it 'stays silent without a coverage field (single-project answers)' do
      expect(render_answer(nil)).not_to include('coverage-notice')
    end

    it 'stays silent on malformed values (strings, non-hashes)' do
      expect(render_answer('searched' => '3', 'total' => '12')).not_to include('coverage-notice')
      expect(render_answer([3, 12])).not_to include('coverage-notice')
    end

    # L7 labels an answer the viewer may read. The viewer-agnostic broadcast
    # (current_user nil) redacts a content-bearing answer — no label under it.
    it 'stays silent under a redacted answer' do
      answer = org_chat.chatposts.create!(
        organisation: organisation, role: 'assistant', content: 'Antwort mit Zahlen.', model_used: 'gpt-x',
        source_coverage: { 'searched' => 3, 'total' => 12 },
        source_citations: [{ 'type' => 'ticket', 'area' => 'tickets', 'id' => SecureRandom.uuid,
                             'project_id' => project.id, 'number' => 1, 'title' => 'T' }]
      )
      render_inline(described_class.new(chatpost: answer, current_user: nil))

      expect(rendered_content).to include(I18n.t('views.organisations.chats.message.redacted'))
      expect(rendered_content).not_to include('coverage-notice')
    end
  end

  # Feinschliff C: the objects an answer NAMES become links, and the whitelist is
  # the answer's own VISIBLE citations. The matching itself is pinned in
  # spec/services/lalabase/citation_inline_links_spec.rb; what belongs here is the
  # seam — that the prose is handed exactly the citations the gate lets through and
  # not one more.
  describe 'object links in the prose' do
    let(:ticket) { create(:ticket, project: project, organisation: organisation) }

    # The prose of an answer that cites TICKETS is only shown to a viewer who may
    # read tickets here — otherwise the render gate blacks it out and there is no
    # sentence to link. The user factory already made the membership; this adds the
    # reach inside the project.
    let!(:reach) { create(:project_permission, user: user, project: project, tickets_access: :read_only) }

    def ticket_citation(ticket_record, used: true, number: 42)
      { 'type' => 'ticket', 'area' => 'tickets', 'id' => ticket_record.id,
        'project_id' => project.id, 'number' => number, 'title' => 'Login bug', 'used' => used }
    end

    def render_answer(content, citations)
      post = chat.chatposts.create!(organisation: organisation, role: 'assistant', content: content)
      post.update_columns(source_citations: citations, model_used: 'test-model')
      render_inline(described_class.new(chatpost: post, current_user: user,
                                        current_organisation: organisation))
    end

    it 'links a ticket the answer names by number' do
      render_answer('Das steht in #42.', [ticket_citation(ticket)])

      expect(page).to have_css(%(a[href*="/tickets/#{ticket.id}"][data-turbo-frame="_top"]))
    end

    it 'does NOT link a citation the gate filtered out of the sources' do
      # `used: false` is the attribution filter: the source list hides it, and the
      # prose must not put it back. Flow anchor above — the same sentence with the
      # same ticket DOES link when the citation is visible.
      render_answer('Das steht in #42.', [ticket_citation(ticket, used: false)])

      expect(page).to have_no_css('a[href*="/tickets/"]')
    end

    it 'does NOT link a ticket that has been deleted since the answer was written' do
      citation = ticket_citation(ticket)
      ticket.destroy!

      render_answer('Das steht in #42.', [citation])

      expect(page).to have_no_css('a[href*="/tickets/"]')
      expect(rendered_content).to include('#42')
    end

    # Review of #624: this render runs once per TOKEN on the streaming path, and a
    # Nokogiri parse per token is quadratic in the answer length (measured: about
    # five times the markdown cost). The reader keeps the LAST render, and the
    # folded final write is the one that carries model_used.
    it 'does not link while the answer is still streaming' do
      post = chat.chatposts.create!(organisation: organisation, role: 'assistant',
                                    content: 'Das steht in #42.')
      post.update_columns(source_citations: [ticket_citation(ticket)]) # no model_used yet

      render_inline(described_class.new(chatpost: post, current_user: user,
                                        current_organisation: organisation))
      expect(page).to have_no_css('a[href*="/tickets/"]')

      # Flow anchor: the same post, once finished, links.
      post.update_columns(model_used: 'test-model')
      render_inline(described_class.new(chatpost: post, current_user: user,
                                        current_organisation: organisation))
      expect(page).to have_css(%(a[href*="/tickets/#{ticket.id}"]))
    end

    it 'leaves a redacted answer without links, because it has no prose to link' do
      other_project = create(:project, organisation: organisation)
      stranger = create(:user, organisation: organisation)
      foreign_ticket = create(:ticket, project: other_project, organisation: organisation)
      citation = ticket_citation(foreign_ticket).merge('project_id' => other_project.id)

      post = chat.chatposts.create!(organisation: organisation, role: 'assistant',
                                    content: 'Das steht in #42.')
      post.update_columns(source_citations: [citation], model_used: 'test-model')
      render_inline(described_class.new(chatpost: post, current_user: stranger,
                                        current_organisation: organisation))

      expect(page).to have_css('[data-testid="redacted-notice"]')
      expect(page).to have_no_css('a[href*="/tickets/"]')
    end

    # R2/R3 seam: ONE numbering, built here over the FULL persisted list, feeds
    # both the prose resolver and the source rows — so a [n] in the text and the
    # row labelled [n] cannot disagree, and neither shifts when the gate filters.
    describe 'the [n] numbering' do
      it 'links a [n] marker in the prose and labels the rows with the same numbers' do
        capability = { 'type' => 'capability', 'id' => SecureRandom.uuid, 'name' => 'Suche' }
        render_answer('Die Suche kann das ([2]).', [capability, ticket_citation(ticket)])

        expect(page).to have_css(%(a[href*="/tickets/#{ticket.id}"]), text: '[2]')
        # visible: :all — the source rows sit inside a collapsed <details>.
        expect(page).to have_css('[data-testid="citation-numbers"]', text: '[2]', visible: :all)
      end

      it 'keeps the full-list positions when the attribution filter hides a source' do
        hidden = ticket_citation(ticket, used: false)
        second = create(:ticket, project: project, organisation: organisation)
        visible = ticket_citation(second, number: 43).merge('id' => second.id)

        render_answer('Laut [2] gilt das. [1] sagt nichts.', [hidden, visible])

        # The visible source keeps ITS number (2), the hidden one's number links
        # nowhere and leaks nothing but the digit the model already wrote.
        expect(page).to have_css(%(a[href*="/tickets/#{second.id}"]), text: '[2]')
        expect(page).to have_no_css(%(a[href*="/tickets/#{ticket.id}"]))
        expect(page).to have_css('[data-testid="citation-numbers"]', text: '[2]', visible: :all)
        expect(page).to have_no_css('[data-testid="citation-numbers"]', text: '[1]', visible: :all)
      end
    end
  end
end
