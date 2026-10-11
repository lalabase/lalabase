# frozen_string_literal: true

require 'rails_helper'

# Guard: which change stands IN the line and which moves to the disclosure.
#
# The drift this pins (Aktivitätenfeed, 10.09.2026): a change to a ticket's
# summary rendered the whole old text struck through and the whole new text
# after it, three to four lines of unreadable strike-through - and a
# "Unterschied ansehen" disclosure below that showed the same again. The way
# out had been built, the full text had not been taken out.
#
# The rule: old and new value together, as plain text, up to
# TimelineHelper::INLINE_CHANGE_LIMIT characters stand in the line; above it
# the line only names the field and the pair lives in the disclosure. It sits
# in the helper because the ticket timeline and the project feed share it -
# decided anywhere else, the two drift apart again.
RSpec.describe TimelineHelper do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation:) }
  let(:ticket) { create(:ticket, project:, organisation:) }
  let(:moment) { Time.zone.local(2026, 9, 10, 11, 22) }

  around { |example| I18n.with_locale(:de) { example.run } }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def change_activity(action:, trackable: ticket, parameters: {}, attribute_changes: {}, at: moment)
    build(:activity, trackable:, organisation:, action:, parameters:, attribute_changes:, created_at: at)
  end

  def title_change(from, to, at: moment)
    change_activity(action: 'title_changed', parameters: { 'from_title' => from, 'to_title' => to }, at:)
  end

  def summary_change(from, to)
    change_activity(action: 'updated', attribute_changes: { 'summary' => [from, to] })
  end

  # Labels come from the fields.* keys when no ticket is passed, which keeps
  # the expected strings independent of a project's attribute definitions.
  def line(activity)
    Capybara.string(helper.timeline_change_line(activity, nil).to_s)
  end

  describe 'the inline limit' do
    # n-1 / n / n+1 around the limit, counted over BOTH values together.
    { 79 => true, 80 => true, 81 => false }.each do |total, inline|
      it "#{inline ? 'keeps' : 'takes out'} a pair of #{total} characters #{inline ? 'in' : 'of'} the line" do
        activity = title_change('a' * 40, 'b' * (total - 40))

        if inline
          expect(line(activity)).to have_css('span.line-through', text: 'a' * 40)
          expect(helper.timeline_change_details(activity, nil)).to be_empty
        else
          expect(line(activity).text).to eq('Titel geändert')
          expect(line(activity)).not_to have_css('.line-through')
          expect(helper.timeline_change_details(activity, nil).map(&:label)).to eq(['Titel'])
        end
      end
    end

    it 'counts the text a reader sees, not the Markdown around it' do
      # 84 characters as stored, 80 once the four asterisks are gone.
      activity = summary_change("**#{'a' * 38}**", 'b' * 42)

      expect(line(activity)).to have_css('span.line-through', text: 'a' * 38)
      expect(line(activity).text).not_to include('**')
    end

    # Decision D5 of the width round (11.09.2026): a pair stands in the line
    # only when both values are ONE line. A paragraph, however short, is not.
    it 'takes a value with a line break out of the line, however short' do
      activity = summary_change("Punkt A\nPunkt B", 'Punkt C')

      expect(line(activity).text).to eq('Zusammenfassung geändert')
      expect(helper.timeline_change_details(activity, nil).map(&:label)).to eq(['Zusammenfassung'])
    end

    it 'reads a trailing line break as the end of the one line, not as a second' do
      activity = summary_change("Alt\n", 'Neu')

      expect(line(activity).text).to eq('Zusammenfassung Alt → Neu')
    end
  end

  describe 'a long text change' do
    let(:old_text) { 'Die erste Fassung beschreibt die **Modifikation** der Produktpflege auf eine einheitliche Technik.' }
    let(:new_text) { 'Die zweite Fassung nennt dazu den Zeitplan, die Verantwortlichen und die offenen Punkte.' }
    let(:activity) { summary_change(old_text, new_text) }

    it 'names only the field in the line, by its display name' do
      expect(line(activity).text).to eq('Zusammenfassung geändert')
      expect(line(activity).text).not_to include('Summary')
    end

    it 'hands the whole pair to the disclosure, as Markdown source' do
      change = helper.timeline_change_details(activity, nil).sole

      expect(change).to have_attributes(label: 'Zusammenfassung', before: old_text, after: new_text, markdown: true)
      expect(helper.timeline_change_inline?(change)).to be(false)
    end

    it 'says the same in English' do
      I18n.with_locale(:en) do
        expect(line(activity).text).to eq('Summary changed')
      end
    end
  end

  describe 'a field name without a model behind it' do
    # The name comes from the trackable's CLASS, read from the stored type
    # without loading the record. A type that names no class any more (a
    # removed model) must not break the row: the humanized column is the last
    # resort, never the rule.
    it 'falls back to the humanized column instead of raising' do
      activity = change_activity(action: 'updated', attribute_changes: { 'summary' => %w[alt neu] })
      activity.trackable_type = 'RemovedModel'

      expect(line(activity).text).to eq('Summary alt → neu')
    end
  end

  describe 'a short change' do
    it 'keeps the old value struck through and the new one in the heading colour' do
      activity = change_activity(action: 'status_changed',
                                 parameters: { 'from_status' => 'In Arbeit', 'to_status' => 'abgenommen' })

      expect(line(activity).text).to eq('Status In Arbeit → abgenommen')
      expect(line(activity)).to have_css('span.line-through.text-cream-500', text: 'In Arbeit')
      expect(line(activity)).to have_css('span.text-heading', text: 'abgenommen')
      expect(line(activity)).not_to have_css('[class*="text-red-"], [class*="text-green-"]')
    end

    it 'strips Markdown from a text value that stays in the line' do
      activity = summary_change('**Alt**', 'Neu mit _Betonung_')

      expect(line(activity).text).to eq('Zusammenfassung Alt → Neu mit Betonung')
    end

    it 'never touches a title: "#103" and "1." are part of the name, not Markdown' do
      activity = title_change('#103 Produktpflege', '1. Entwurf user_id')

      expect(line(activity).text).to eq('Titel #103 Produktpflege → 1. Entwurf user_id')
    end
  end

  describe 'several fields in one change' do
    let(:activity) do
      change_activity(action: 'updated', trackable: project,
                      attribute_changes: { 'name' => %w[Alpha Beta], 'description' => %w[alt neu] })
    end

    it 'names the fields in one sentence' do
      expect(line(activity).text).to eq('Name und Beschreibung geändert')
    end

    it 'shows every pair in the disclosure' do
      expect(helper.timeline_change_details(activity, nil).map(&:label)).to eq(%w[Name Beschreibung])
    end

    it 'reads the text column as Markdown and the string column as a name' do
      markdown = helper.timeline_change_details(activity, nil).to_h { |change| [change.label, change.markdown] }

      expect(markdown).to eq('Name' => false, 'Beschreibung' => true)
    end
  end

  # Review finding (11.09.2026): generic updates counted every column as
  # Markdown, so a project renamed "1. Entwurf" read "Entwurf" in its row. A
  # string column holds a name, and a name is never touched.
  describe 'a name in a generic update' do
    it 'keeps a project name exactly as typed' do
      activity = change_activity(action: 'updated', trackable: project,
                                 attribute_changes: { 'name' => ['1. Entwurf', '#2 _Relaunch_'] })

      expect(line(activity).text).to eq('Name 1. Entwurf → #2 _Relaunch_')
    end
  end

  describe 'a collapsed run' do
    def step(action, parameters, second)
      change_activity(action:, parameters:, at: moment + second.seconds)
    end

    def run_of(*steps)
      Activities::RunCollapser::ActivityRun.new(steps)
    end

    def run_line(run)
      Capybara.string(helper.timeline_run_line(run, nil).to_s).text
    end

    it 'names the fields it changed instead of counting them' do
      run = run_of(step('status_changed', { 'from_status' => 'Offen', 'to_status' => 'Fertig' }, 0),
                   step('priority_changed', { 'from_priority' => 'Low', 'to_priority' => 'Normal' }, 1),
                   step('title_changed', { 'from_title' => 'Alt', 'to_title' => 'Neu' }, 2))

      expect(run_line(run)).to eq('Status, Priorität und Titel geändert')
      I18n.with_locale(:en) { expect(run_line(run)).to eq('Status, Priority, and Title changed') }
    end

    it 'leaves out a field that ended where it started' do
      run = run_of(step('status_changed', { 'from_status' => 'Offen', 'to_status' => 'Fertig' }, 0),
                   step('status_changed', { 'from_status' => 'Fertig', 'to_status' => 'Offen' }, 1),
                   step('title_changed', { 'from_title' => 'Alt', 'to_title' => 'Neu' }, 2))

      expect(run_line(run)).to eq('Titel geändert')
    end

    it 'names every touched field when all of them cancelled out' do
      run = run_of(step('status_changed', { 'from_status' => 'Offen', 'to_status' => 'Fertig' }, 0),
                   step('status_changed', { 'from_status' => 'Fertig', 'to_status' => 'Offen' }, 1),
                   step('priority_changed', { 'from_priority' => 'Low', 'to_priority' => 'High' }, 2),
                   step('priority_changed', { 'from_priority' => 'High', 'to_priority' => 'Low' }, 3))

      expect(run_line(run)).to eq('Status und Priorität geändert')
    end

    it 'moves a long net title change into the disclosure: first old value, last new value' do
      run = run_of(step('title_changed', { 'from_title' => 'a' * 45, 'to_title' => 'b' * 45 }, 0),
                   step('title_changed', { 'from_title' => 'b' * 45, 'to_title' => 'c' * 45 }, 1))

      expect(run_line(run)).to eq('Titel geändert')
      expect(helper.timeline_run_details(run, nil).sole).to have_attributes(before: 'a' * 45, after: 'c' * 45)
    end

    it 'leaves a field that ended where it started out of the disclosure too, not only out of the line' do
      run = run_of(step('status_changed', { 'from_status' => 'Offen', 'to_status' => 'Fertig' }, 0),
                   step('title_changed', { 'from_title' => 'a' * 45, 'to_title' => 'b' * 45 }, 1),
                   step('title_changed', { 'from_title' => 'b' * 45, 'to_title' => 'a' * 45 }, 2))

      expect(run_line(run)).to eq('Status geändert')
      expect(helper.timeline_run_details(run, nil)).to be_empty
    end

    it 'keeps a short net title change in the line and adds nothing to the disclosure' do
      run = run_of(step('title_changed', { 'from_title' => 'Alt', 'to_title' => 'Mitte' }, 0),
                   step('title_changed', { 'from_title' => 'Mitte', 'to_title' => 'Neu' }, 1))

      expect(run_line(run)).to eq('Titel Alt → Neu')
      expect(helper.timeline_run_details(run, nil)).to be_empty
    end
  end

  # A bulk run is ONE line in the feed (doc/ticket_bulk_edit_plan.md, D12). It
  # fell back to Activity#message: the person's name first and the whole list
  # of changes after it, 99 characters in the feed on 11.09.2026. The row's
  # second line already names the person; the line says how many tickets and
  # what happened, and a list too long for it waits in the disclosure.
  describe 'a bulk run' do
    let(:short_change) { 'Status auf „In Bearbeitung“ gesetzt' }
    let(:long_changes) do
      'Status auf „In Bearbeitung“ gesetzt, Priorität auf „Hoch“ gesetzt, Tags: +Frontend, +Relaunch'
    end

    def bulk(action, **parameters)
      change_activity(action:, trackable: project, parameters: parameters.transform_keys(&:to_s))
    end

    it 'names the count and a short change, without the person' do
      activity = bulk('tickets_bulk_changed', count: 4, changes: short_change)

      expect(line(activity).text).to eq("4 Tickets geändert: #{short_change}")
      expect(line(activity).text).not_to include(activity.actor.full_name)
      expect(helper.timeline_change_details(activity, nil)).to be_empty
    end

    it 'leaves a long list of changes to the disclosure' do
      activity = bulk('tickets_bulk_changed', count: 4, changes: long_changes)

      expect(line(activity).text).to eq('4 Tickets geändert')
      expect(helper.timeline_change_details(activity, nil).sole)
        .to have_attributes(label: 'Änderungen', text: long_changes)
    end

    it 'says a taken-back bulk change in 79 characters instead of 99' do
      activity = bulk('tickets_bulk_undone', count: 2, changes: short_change)

      expect(line(activity).text).to eq("Sammeländerung an 2 Tickets zurückgenommen: #{short_change}")
      expect(line(activity).text.length).to eq(79)
    end

    it 'counts one ticket in the singular' do
      expect(line(bulk('tickets_bulk_changed', count: 1, changes: short_change)).text)
        .to eq("1 Ticket geändert: #{short_change}")
    end

    # A real move stores `changes` too (Actors::MoveTickets#track_run, on both
    # sides): "nach „Relaunch“ verschoben". The sentence already says it, so a
    # move has no detail, and the line must not say it twice.
    it 'names where the tickets went and where they came from, and never repeats the move' do
      moved = 'nach „Relaunch“ verschoben'

      expect(line(bulk('tickets_bulk_moved', count: 3, target: 'Relaunch', changes: moved)).text)
        .to eq('3 Tickets nach „Relaunch“ verschoben')
      expect(line(bulk('tickets_bulk_moved_in', count: 3, source: 'Altprojekt', changes: moved)).text)
        .to eq('3 Tickets aus „Altprojekt“ erhalten')
    end

    # n / n+1 around the limit, on the WHOLE line: "4 Tickets geändert: " is
    # 20 characters, so a list of 60 ends the line at exactly 80.
    it 'keeps a list at exactly 80 characters in the line and moves one at 81 to the disclosure' do
      fits = bulk('tickets_bulk_changed', count: 4, changes: 'a' * 60)
      expect(line(fits).text.length).to eq(80)
      expect(helper.timeline_change_details(fits, nil)).to be_empty

      too_long = bulk('tickets_bulk_changed', count: 4, changes: 'a' * 61)
      expect(line(too_long).text).to eq('4 Tickets geändert')
      expect(helper.timeline_change_details(too_long, nil).sole.text).to eq('a' * 61)
    end

    # A delete stores at most ten numbers. Ten numbers after "12 Tickets
    # gelöscht" would read as the whole list; the rest is counted instead.
    it 'counts the deleted tickets the stored numbers leave out' do
      expect(line(bulk('tickets_bulk_deleted', count: 3, numbers: '#12, #13')).text)
        .to eq('3 Tickets gelöscht: #12, #13 und 1 weiteres')

      first_ten = (1..10).map { |number| "##{number}" }.join(', ')
      expect(line(bulk('tickets_bulk_deleted', count: 12, numbers: first_ten)).text)
        .to eq("12 Tickets gelöscht: #{first_ten} und 2 weitere")
    end

    it 'lists the deleted numbers while they fit and leaves ten long ones to the disclosure' do
      expect(line(bulk('tickets_bulk_deleted', count: 2, numbers: '#12, #13')).text)
        .to eq('2 Tickets gelöscht: #12, #13')

      many = (1001..1010).map { |number| "##{number}" }.join(', ')
      activity = bulk('tickets_bulk_deleted', count: 10, numbers: many)
      expect(line(activity).text).to eq('10 Tickets gelöscht')
      expect(helper.timeline_change_details(activity, nil).sole).to have_attributes(label: 'Tickets', text: many)
    end

    it 'says the same in English' do
      I18n.with_locale(:en) do
        expect(line(bulk('tickets_bulk_changed', count: 4, changes: 'Status set')).text)
          .to eq('4 tickets changed: Status set')
        expect(line(bulk('tickets_bulk_undone', count: 1, changes: 'Status set')).text)
          .to eq('Bulk change to 1 ticket taken back: Status set')
        expect(line(bulk('tickets_bulk_deleted', count: 4, numbers: '#12, #13')).text)
          .to eq('4 tickets deleted: #12, #13 and 2 more')
      end
    end
  end
end
