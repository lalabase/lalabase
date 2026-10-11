# frozen_string_literal: true

require 'rails_helper'

# What: TicketColumnsHelper, the two forms of a list column (cell, item below the title).
# Type: helper spec with real records, the time totals stubbed.
# Why: the item below the title must stay EMPTY when the ticket has no value (the
#   stylesheet hides an empty span, and an item that says "Tags:" with nothing
#   behind it would show), and a select must show its label, not its stored key.
RSpec.describe TicketColumnsHelper, type: :helper do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, creator: user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    allow(helper).to receive(:current_user).and_return(user)
  end

  describe '#initial_column_fit' do
    let(:ranked) { [{ rank: 1 }, { rank: 2 }, { rank: 3 }] }

    it 'is every ranked column with the detail closed and one with it open' do
      expect(helper.initial_column_fit(ranked, content_open: false)).to eq(3)
      expect(helper.initial_column_fit(ranked, content_open: true)).to eq(1)
    end

    it 'never exceeds the columns there are' do
      expect(helper.initial_column_fit([], content_open: true)).to eq(0)
    end
  end

  describe '#ticket_column_cell' do
    # A cell without a value shows NOTHING since 07.09.2026 - not an en dash and
    # not the word "ohne Zuweisung". In a table the blank is already the sign for
    # nothing, and a column of pale placeholders says it a dozen times over.
    it 'shows nothing for a custom attribute without a value' do
      create(:ticket_attribute_definition, project: project, name: 'notiz')
      html = helper.ticket_column_cell(ticket, key: 'custom_notiz', label: 'Notiz', custom: true, type: 'text')
      expect(html).to be_nil
    end

    it 'shows nothing when nobody works on the ticket' do
      html = helper.ticket_column_cell(ticket, key: 'assignees', label: 'Zugewiesen')
      expect(html).to be_nil
    end

    # Adaptive density (user, 08.09.2026): two names never fit the 120px
    # column, two chips do. The rule itself is pinned in
    # application_helper_spec; this pins that the cell goes through it.
    it 'shows chip and name while one person works on the ticket' do
      erika = create(:user, first_name: 'Erika', last_name: 'Musterfrau')
      solo = create(:ticket, project: project, creator: user, assignees: [erika])

      html = Capybara.string(helper.ticket_column_cell(solo, key: 'assignees', label: 'Zugewiesen'))
      expect(html).to have_css('span.neo-user-avatar[title="Erika Musterfrau"]')
      expect(html).to have_text('Erika Musterfrau')
    end

    it 'shows chips only once several people do, the viewer first' do
      erika = create(:user, first_name: 'Erika', last_name: 'Musterfrau')
      shared = create(:ticket, project: project, creator: user, assignees: [erika, user])

      html = Capybara.string(helper.ticket_column_cell(shared, key: 'assignees', label: 'Zugewiesen'))
      expect(html.all('span.neo-user-avatar').map { |chip| chip[:title] }).to eq([user.display_name, 'Erika Musterfrau'])
      expect(html).to have_no_text('Erika Musterfrau')
    end
  end

  # The "Subs" column (Tickets::SubtaskCountsCache counts, this renders). The
  # request spec covers the list; these pin the two forms at their boundaries.
  describe 'the subtask_count column' do
    let(:column) { { key: 'subtask_count', label: 'Subs', type: 'count' } }
    let(:parent) { create(:ticket, project: project, creator: user) }

    before do
      create(:ticket_attribute_definition,
             project: project, name: 'status', field_type: 'select', system: true,
             options: { 'allowed_values' => [
               { 'value' => 'Offen', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] },
               { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
             ] })
    end

    def child(status)
      create(:ticket, project: project, creator: user, parent: parent, custom_attributes: { 'status' => status })
    end

    # Boundary: children, none done. The cell hides on TOTAL zero, never on
    # DONE zero - "0/2" is the most useful thing the column can say.
    it 'shows 0/n when no sub-ticket is done' do
      child('Offen')
      child('Offen')

      expect(Capybara.string(helper.ticket_column_cell(parent, column))).to have_text(%r{\A0/2\z})
    end

    it 'shows nothing in either form for a ticket without sub-tickets' do
      expect(helper.ticket_column_cell(parent, column)).to be_nil
      expect(helper.ticket_column_meta_text(parent, column)).to be_nil
    end

    # The item under the title stands alone in a line of other values, so it
    # carries the column's name; a bare "1/2" there would read as a date or a page.
    it 'names the column in the item under the title' do
      child('Erledigt')
      child('Offen')

      expect(Capybara.string(helper.ticket_column_meta_text(parent, column)).text).to eq('Subs 1/2')
    end

    # Same boundary for the second form: it hides on TOTAL zero only.
    it 'keeps 0/n in the item under the title' do
      child('Offen')
      child('Offen')

      expect(Capybara.string(helper.ticket_column_meta_text(parent, column)).text).to eq('Subs 0/2')
    end

    # config/initializers/i18n.rb falls back to :de, so a missing English key
    # renders the German text and no page looks broken. Asked without the
    # fallback, per locale, for every key the column brings.
    %w[
      models.view_configuration.columns.subtask_count
      views.organisations.tickets.tickets_results.subtask_count_cell
      views.organisations.tickets.tickets_results.subtask_count_meta
    ].product(%i[de en]).each do |key, locale|
      it "has #{key} in #{locale} of its own" do
        expect(I18n.exists?(key, locale, fallback: false)).to be(true)
      end
    end

    it 'counts the type as a number, so cell and head sit on the right' do
      expect(helper.column_align_class(column)).to eq('text-end')
    end
  end

  # The "Wartet" column (doc/ticket_relations_plan.md, revision 4, §8.3). Tickets::Waiting
  # counts, Tickets::WaitingCountsCache holds a page, this renders: an hourglass and the number
  # of open tickets the row waits on, nothing when it waits on none.
  describe 'the waiting column' do
    let(:column) { { key: 'waiting', label: 'Wartet', type: 'count' } }
    let(:waiter) { ticket_with_status('Offen') }
    let(:label) { I18n.t('views.organisations.tickets.shared.relations.waiting_mark', count: 2) }

    before do
      create(:ticket_attribute_definition,
             project: project, name: 'status', field_type: 'select', system: true,
             options: { 'allowed_values' => [
               { 'value' => 'Offen', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] },
               { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
             ] })
    end

    # Setup only: each create loads its organisation, which Prosopite reports from the second on.
    def ticket_with_status(status)
      Prosopite.pause { create(:ticket, project: project, creator: user, custom_attributes: { 'status' => status }) }
    end

    def blocked_by(*statuses, of: waiter)
      statuses.each do |status|
        blocker = ticket_with_status(status)
        Prosopite.pause { TicketRelation.create!(source_ticket: blocker, target_ticket: of, relation_type: :blocks) }
      end
    end

    it 'shows the hourglass and the number of open blockers, labelled for the ear' do
      blocked_by('Offen', 'Offen', 'Erledigt')

      cell = Capybara.string(helper.ticket_column_cell(waiter, column))
      expect(cell).to have_text(/\A\s*2\s*\z/)
      expect(cell).to have_css('i.bi.bi-hourglass-split[aria-hidden="true"]')
      expect(cell).to have_css(%([role="img"][aria-label="#{label}"][title="#{label}"]))
    end

    it 'shows nothing in either form for a ticket that waits on nothing' do
      expect(helper.ticket_column_cell(waiter, column)).to be_nil
      expect(helper.ticket_column_meta_text(waiter, column)).to be_nil
    end

    it 'shows nothing while every blocker is done' do
      blocked_by('Erledigt')

      expect(helper.ticket_column_cell(waiter, column)).to be_nil
      expect(helper.ticket_column_meta_text(waiter, column)).to be_nil
    end

    # A done ticket waits on nothing, whatever still points at it (plan §5.1).
    it 'shows nothing on a done ticket with an open blocker' do
      done = ticket_with_status('Erledigt')
      blocked_by('Offen', of: done)

      expect(helper.ticket_column_cell(done, column)).to be_nil
    end

    # Like "Subs 1/2": the item stands in a line of other values and names what it counts.
    it 'names the state in the item under the title' do
      blocked_by('Offen', 'Offen')

      expect(Capybara.string(helper.ticket_column_meta_text(waiter, column)).text.strip)
        .to eq(I18n.t('views.organisations.tickets.tickets_results.waiting_meta', count: 2))
    end

    it 'is a number, so cell and head sit on the right' do
      expect(helper.column_align_class(column)).to eq('text-end')
    end

    %w[
      models.view_configuration.columns.waiting
      views.organisations.tickets.tickets_results.waiting_meta
      views.organisations.tickets.shared.relations.waiting_mark.one
      views.organisations.tickets.shared.relations.waiting_mark.other
    ].product(%i[de en]).each do |key, locale|
      it "has #{key} in #{locale} of its own" do
        expect(I18n.exists?(key, locale, fallback: false)).to be(true)
      end
    end
  end
end
