# frozen_string_literal: true

require 'rails_helper'

# Bezugs-Sammlung S1 (§8.1): the chip that says WHICH objects the thread is
# about. Two questions belong here and nowhere else: whether the chip shows
# itself at all, and what it puts on the screen when it does. The narrowing
# behind it is Tools::Scope's business (scope_spec), the write is the request
# spec's.
RSpec.describe Neo::Chat::ReferenceChipComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # Admin: the reference resolves through the asker's READ reach, and this spec
  # is about the chip, not about the permission matrix. The out-of-reach cases
  # below take the reach away in ways an admin cannot out-rank (archived project,
  # another organisation) -- see scope_spec for the per-permission table.
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
  end

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Nordlicht Software') }
  end

  def ticket(title: 'Anmeldung schlaegt fehl')
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: title)
    end
  end

  def chat_with(reference)
    ActsAsTenant.with_tenant(organisation) do
      create(:chat, :org_thread, organisation: organisation, user: user, scope_ticket: reference)
    end
  end

  def render_chip(chat, viewer = user)
    render_inline(described_class.new(chat: chat, current_user: viewer, current_organisation: organisation))
  end

  it 'names the referenced ticket by number and title' do
    referenced = ticket

    render_chip(chat_with(referenced))

    expect(page.text).to include('Bezug').and include("##{referenced.number} Anmeldung schlaegt fehl")
  end

  # The chip is the only place the panel can read WHICH objects the thread points
  # at: the panel's node is permanent, so the server never tells it anything, and
  # the chip is the last thing the server said. The offer compares these keys with
  # the page's own to decide between offering, offering a SWITCH, and staying
  # quiet. Without them the offer would appear on the very ticket the thread
  # already references, which is the one case where there is nothing to take.
  #
  # The COMPOSITE key of §7.1 and not a bare id: a collection may hold two types,
  # and a bare id would make a meeting and a ticket that happen to share one look
  # like the same entry.
  it 'says which objects it stands for, for the offer to compare against' do
    referenced = ticket

    render_chip(chat_with(referenced))

    expect(page.find('[data-reference-keys]')['data-reference-keys']).to eq("Ticket:#{referenced.id}")
  end

  # T-4 (plan §12), the half that is easy to leave out. "Leaves no trace" is a
  # claim about EVERY channel the chip owns, and data-reference-keys is a channel
  # -- the panel reads it and decides whether to offer. A key without a pill would
  # make the panel believe a reference stands that the user can neither see nor
  # remove.
  #
  # ⚠️ Written with a SURVIVOR beside the dead entry, and that is not decoration.
  # Measured: with only one entry, #render? already answers false and the whole
  # element is gone, so a version reading the STORED column instead of the resolved
  # collection stays green -- the leak this cell exists to catch would be invisible
  # the moment S2 allows a partly resolvable list. Two entries make the component
  # render, so the key list has to do the refusing itself.
  #
  # Stored past the S1 limit on purpose (update_column bypasses the model): the
  # claim is about the READ path, which S2 opens to ten.
  it 'leaves no key behind for an entry that stopped resolving, next to one that still does' do
    elsewhere = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Zweitprojekt') }
    doomed = ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: elsewhere, organisation: organisation, creator: user, title: 'Verschwindet')
    end
    alive = ticket
    chat = chat_with(nil)
    ActsAsTenant.with_tenant(organisation) do
      chat.update_column(:scope_references, [
                           Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: doomed.id),
                           Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: alive.id)
                         ])
    end

    render_chip(chat.reload)
    expect(page).to have_css("[data-reference-keys='Ticket:#{doomed.id} Ticket:#{alive.id}']", visible: :all)

    ActsAsTenant.with_tenant(organisation) { elsewhere.update!(archived_at: Time.current) }

    render_chip(chat.reload)
    expect(page.find('[data-reference-keys]', visible: :all)['data-reference-keys'])
      .to eq("Ticket:#{alive.id}")
    expect(page.text).to include('Anmeldung schlaegt fehl')
    expect(page.text).not_to include('Verschwindet')
  end

  # The last entry going away takes the whole element with it, keys included.
  it 'leaves nothing at all once the last reference stops resolving' do
    referenced = ticket
    chat = chat_with(referenced)

    render_chip(chat)
    expect(page).to have_css("[data-reference-keys='Ticket:#{referenced.id}']", visible: :all)

    ActsAsTenant.with_tenant(organisation) { project.update!(archived_at: Time.current) }

    render_chip(chat.reload)
    expect(page).to have_no_css('[data-reference-keys]', visible: :all)
  end

  # T-3 (plan §12): fail-closed. A type the registry does not know is not a chip,
  # not an exception and not a blank pill -- it is simply not there.
  it 'ignores an entry of a type the registry does not know' do
    chat = chat_with(nil)
    ActsAsTenant.with_tenant(organisation) do
      chat.update_column(:scope_references, [{ 'type' => 'Invoice', 'id' => SecureRandom.uuid }])
    end

    render_chip(chat.reload)

    expect(page.text).to be_blank
  end

  it 'stays away when the thread has no reference' do
    render_chip(chat_with(nil))

    expect(page.text).to be_blank
  end

  it 'stays away on a project thread' do
    project_chat = ActsAsTenant.with_tenant(organisation) do
      create(:chat, organisation: organisation)
    end

    render_chip(project_chat)

    expect(page.text).to be_blank
  end

  # The rule this chip exists to keep: it shows the RESOLVED reference, never the
  # stored column. Both halves in one example on purpose -- "renders nothing" is
  # true of a component that renders nothing ever, so the positive case has to
  # stand right next to it with the same chat and the same user.
  it 'drops the reference, name and all, once its project is archived' do
    referenced = ticket
    chat = chat_with(referenced)

    render_chip(chat)
    expect(page.text).to include("##{referenced.number}")

    ActsAsTenant.with_tenant(organisation) { project.update!(archived_at: Time.current) }

    render_chip(chat.reload)
    expect(page.text).to be_blank
  end

  # The same rule along the dimension that matters most, and the one the tenant
  # cannot cover for us: rights change AFTER the reference was stored. Measured
  # while writing this file -- an earlier version used a ticket of another
  # organisation, and it stayed green with the resolution replaced by a plain
  # `chat.scope_ticket`, because acts_as_tenant had already done the work. A
  # colleague of the SAME organisation who never had (or has lost) access to the
  # project is the case only Tools::Scope#references answers.
  #
  # The positive half stands in the same example with the same chat: "renders
  # nothing" is true of a component that renders nothing ever.
  it 'drops the name the moment the asker may not read its project' do
    colleague = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: colleague, organisation: organisation,
                          role: create(:role, organisation: organisation, is_default: true), active: true)
    end
    referenced = ticket(title: 'Geheimes Kundenprojekt')
    chat = ActsAsTenant.with_tenant(organisation) do
      create(:chat, :org_thread, organisation: organisation, user: colleague, scope_ticket: referenced)
    end

    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: colleague, project: project, tickets_access: 'read_only')
    end
    render_chip(chat, colleague)
    expect(page.text).to include('Geheimes Kundenprojekt')

    ActsAsTenant.with_tenant(organisation) { ProjectPermission.find_by(user: colleague, project: project).destroy! }

    render_chip(chat.reload, colleague)
    expect(page.text).to be_blank
  end

  # The title is free text and can be a pasted stacktrace. The cap is Ruby's, not
  # the CSS truncation's: the tooltip and the accessible name carry the value too.
  it 'caps a long title instead of trusting the CSS to hide it' do
    # Within Ticket::TITLE_MAX_LENGTH, far beyond the cap.
    long = "Beim Speichern #{'sehr ' * 45}langer Titel"

    render_chip(chat_with(ticket(title: long)))

    expect(page.text.strip.length).to be <= described_class::MAX_TITLE_CHARS + 40
    expect(page).to have_css("span[title$='...']")
  end

  # A multi-line title must not spend the cap on newlines and must not break the
  # one-line pill.
  it 'collapses whitespace before it cuts' do
    render_chip(chat_with(ticket(title: "Absturz\n\n  beim   Speichern")))

    expect(page.text).to include('Absturz beim Speichern')
  end

  # The only destructive control in the row, so someone on the keyboard has to see
  # where they are standing. The first version carried focus:outline-none with
  # nothing put back -- the select's reason for that class does not carry over,
  # @tailwindcss/forms rings form fields, not buttons.
  # A 10px glyph with 4px of side padding was an 18x10 target; the offer strip's
  # dismiss button grew a 24x24 hit box for the same reason, and the only
  # destructive control in the row deserves no less.
  it 'gives the remove button a 24px hit box' do
    render_chip(chat_with(ticket))

    expect(page).to have_css("button[class*='h-6'][class*='w-6']", visible: :all)
  end

  it 'gives the remove button a visible keyboard focus' do
    render_chip(chat_with(ticket))

    expect(page).to have_css("button[class*='focus-visible:ring-2']", visible: :all)
    expect(page).to have_no_css("button[class*='focus:ring-0']", visible: :all)
  end

  # The write this chip carries is a REMOVAL of ONE entry, and since S1 it NAMES
  # what it removes: a DELETE on that entry's own address (§7.1) rather than two
  # blank columns. The project the reference implied still goes with it, but that
  # rule moved to where it belongs -- Actors::RemoveChatReference clears
  # scope_project_id once the list runs empty, so it holds for every caller
  # instead of for whoever remembers to send a second hidden field.
  it 'removes one named entry, on that entry\'s own address' do
    referenced = ticket

    render_chip(chat_with(referenced))

    # The key travels UNESCAPED in the segment: ":" is a legal path character, so
    # Rails leaves it alone and the route's default constraint ([^/.?]+) matches
    # it. Asserted literally, because an escaped colon here would mean the panel
    # and the server disagree about what the address of an entry is.
    form = page.find('form', visible: :all)
    expect(form['action']).to end_with("/references/Ticket:#{referenced.id}")
    expect(page).to have_css("input[name='_method'][value='delete']", visible: :all)
    # And no column write left over: the old chip sent two blank hidden fields,
    # and leaving one of them behind would write a column the new route owns.
    expect(page).to have_no_css("input[name^='chat[']", visible: :all)
  end

  # T-12 (plan §12): the three states of §8.1. Nothing, the pill of today, and a
  # disclosure from two entries on. The middle state is the one the S1 code
  # already produced; the other two are what this cut adds, so all three stand
  # here together -- "renders a disclosure" is true of a component that renders
  # one for a single entry too, which would be the wrong answer.
  #
  # ⚠️ Stored past the S1 limit with update_column throughout this block. The
  # LIMIT is Actors::AddChatReference's business and rises in the next step; what
  # is asserted here is the READ path, and it has to be right before the write
  # path can produce these lists at all. (Same technique as T-6 in scope_spec.)
  describe 'a collection of more than one (S2, §8.1)' do
    def chat_referencing(*records)
      chat = chat_with(nil)
      ActsAsTenant.with_tenant(organisation) do
        chat.update_column(:scope_references, records.map do |record|
          Assistant::ReferenceRegistry.stored_entry(type: record.class.name, id: record.id)
        end)
      end
      chat.reload
    end

    it 'stays the single pill it always was for a single reference' do
      render_chip(chat_referencing(ticket))

      expect(page).to have_no_css('details', visible: :all)
      expect(page.text).to include('Anmeldung schlaegt fehl')
    end

    it 'collapses two or more into a disclosure that counts them by type' do
      render_chip(chat_referencing(ticket(title: 'Erstes'), ticket(title: 'Zweites')))

      expect(page).to have_css('details summary', visible: :all)
      expect(page.find('details summary', visible: :all).text).to include('Bezug').and include('2 Aufgaben')
    end

    # ⚠️ Deliberately NOT rendered, and that is the finding: with one registered
    # type a group of ONE is unreachable here (one entry renders the pill, and the
    # only group there can be holds all of them). It becomes reachable in S3 the
    # day a second type joins -- "1 Aufgabe, 2 Gespraeche" -- and a count key
    # without a `one` branch does not print "1 Aufgaben" then, it RAISES
    # (I18n::InvalidPluralizationData). So the branch is pinned where it is real:
    # on the value, in both locales, against a literal.
    it 'has both plural forms of every group label, in both languages' do
      expect(I18n.t('views.organisations.assistant_panels.reference.types.ticket', count: 1, locale: :de))
        .to eq('1 Aufgabe')
      expect(I18n.t('views.organisations.assistant_panels.reference.types.ticket', count: 2, locale: :de))
        .to eq('2 Aufgaben')
      expect(I18n.t('views.organisations.assistant_panels.reference.types.ticket', count: 1, locale: :en))
        .to eq('1 task')
      expect(I18n.t('views.organisations.assistant_panels.reference.types.ticket', count: 2, locale: :en))
        .to eq('2 tasks')
    end

    # The knowledge objects (doc/assistent_wissen_kontext_plan.md, step 1): a
    # mixed collection counts by type, in REGISTRY order, with the group of ONE
    # that was unreachable above now real -- and the words are the ones the
    # knowledge list already uses for these objects (Notiz, Datei).
    it 'counts a mixed collection by type, in registry order' do
      note = ActsAsTenant.with_tenant(organisation) do
        create(:note, project: project, organisation: organisation, creator: user, title: 'Einarbeitung')
      end
      document = ActsAsTenant.with_tenant(organisation) do
        document = create(:document, project: project, organisation: organisation, creator: user)
        version = create(:document_version, document: document, organisation: organisation, title: 'Angebot')
        document.update!(current_version: version)
        document
      end

      render_chip(chat_referencing(document, note, ticket(title: 'Erstes'), ticket(title: 'Zweites')))

      expect(page.find('details summary', visible: :all).text).to include('2 Aufgaben, 1 Notiz, 1 Datei')
      expect(page).to have_css('details i.bi-journal-text', visible: :all)
      expect(page).to have_css('details i.bi-file-earmark-text', visible: :all)
      expect(page.text).to include('Einarbeitung').and include('Angebot')
    end

    it 'has both plural forms of the knowledge group labels, in both languages' do
      base = 'views.organisations.assistant_panels.reference.types'
      expect(I18n.t("#{base}.note", count: 1, locale: :de)).to eq('1 Notiz')
      expect(I18n.t("#{base}.note", count: 2, locale: :de)).to eq('2 Notizen')
      expect(I18n.t("#{base}.document", count: 1, locale: :de)).to eq('1 Datei')
      expect(I18n.t("#{base}.document", count: 2, locale: :de)).to eq('2 Dateien')
      expect(I18n.t("#{base}.note", count: 1, locale: :en, fallback: false)).to eq('1 note')
      expect(I18n.t("#{base}.note", count: 2, locale: :en, fallback: false)).to eq('2 notes')
      expect(I18n.t("#{base}.document", count: 1, locale: :en, fallback: false)).to eq('1 file')
      expect(I18n.t("#{base}.document", count: 2, locale: :en, fallback: false)).to eq('2 files')
    end

    # What the summary counts is the RESOLVED collection, exactly like the pills
    # and like data-reference-keys. A count read off the stored column would say
    # "3 Aufgaben" over a list of two -- and it would say it about an object the
    # asker may not see, which is the one thing this chip never does.
    it 'counts what still resolves, not what is stored' do
      elsewhere = ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation, name: 'Zweitprojekt')
      end
      doomed = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: elsewhere, organisation: organisation, creator: user, title: 'Verschwindet')
      end
      chat = chat_referencing(ticket(title: 'Erstes'), ticket(title: 'Zweites'), doomed)

      render_chip(chat)
      expect(page.find('details summary', visible: :all).text).to include('3 Aufgaben')

      ActsAsTenant.with_tenant(organisation) { elsewhere.update!(archived_at: Time.current) }

      render_chip(chat.reload)
      expect(page.find('details summary', visible: :all).text).to include('2 Aufgaben')
      expect(page.text).not_to include('Verschwindet')
    end

    it 'lists every entry with its title when opened' do
      first = ticket(title: 'Erstes')
      second = ticket(title: 'Zweites')

      render_chip(chat_referencing(first, second))

      expect(page.text).to include("##{first.number} Erstes").and include("##{second.number} Zweites")
    end

    # Every ROW carries its own address, not just the first one. A loop that
    # renders one form for the whole list would look right and remove the wrong
    # entry -- or the same one twice.
    it 'gives every entry its own remove address' do
      first = ticket(title: 'Erstes')
      second = ticket(title: 'Zweites')

      render_chip(chat_referencing(first, second))

      actions = page.all('form', visible: :all).map { |form| form['action'] }
      expect(actions).to contain_exactly(
        a_string_ending_with("/references/Ticket:#{first.id}"),
        a_string_ending_with("/references/Ticket:#{second.id}")
      )
    end

    # The icon comes from the map that already exists, reached through the
    # registry's `citation_type`. A second icon map here would be the FOURTH card
    # the whole plan is written to avoid (§2.3), and it would drift the first time
    # a type changes its glyph.
    it 'takes the type icon from the citation map instead of a second one' do
      render_chip(chat_referencing(ticket(title: 'Erstes'), ticket(title: 'Zweites')))

      icon = Neo::Chat::CitationListComponent::ICON_MAP.fetch('ticket')
      expect(page).to have_css("i.#{icon}", count: 2, visible: :all)
    end

    # §8.1: the disclosure state is DOM state and the whole row is REPLACED after
    # every write, so what the server renders is the state afterwards. The cross
    # sits inside the open list -- a row that comes back closed after a removal
    # makes the second removal a three-click affair.
    it 'comes back open when the request was a reference write' do
      chat = chat_referencing(ticket(title: 'Erstes'), ticket(title: 'Zweites'))

      render_inline(described_class.new(chat: chat, current_user: user,
                                        current_organisation: organisation, expanded: true))

      expect(page).to have_css('details[open]', visible: :all)
    end

    it 'stays closed on every other render' do
      render_chip(chat_referencing(ticket(title: 'Erstes'), ticket(title: 'Zweites')))

      expect(page).to have_css('details', visible: :all)
      expect(page).to have_no_css('details[open]', visible: :all)
    end

    # §8.1, the layout half that markup CAN answer: the open list has to become a
    # full-width item of the context row, or it wedges itself between the
    # reference and the scope chip. Where it actually lands is measured with
    # stylesheets on (assistant_panel_layout_spec); this cell only pins that the
    # instruction is on the element that carries the `open` attribute -- the
    # variant applies to that element and to no ancestor of it.
    it 'tells the row to give the open list its own line' do
      render_chip(chat_referencing(ticket(title: 'Erstes'), ticket(title: 'Zweites')))

      expect(page).to have_css('details[class*="open:basis-full"]', visible: :all)
    end
  end
end
