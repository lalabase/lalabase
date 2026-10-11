# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NeoActivityTimelineComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation:) }
  let(:user) { create(:user, first_name: 'Gabi', last_name: 'Boyke') }
  let(:ticket) { create(:ticket, project:, organisation:, title: 'Logo einsetzen') }

  subject(:component) { described_class.new(activities:, project:) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user:, organisation:)
  end

  after { ActsAsTenant.current_tenant = nil }

  def rendered_component
    render_inline(component)
  end

  context 'without activities' do
    let(:activities) { [] }

    it 'renders the empty timeline frame' do
      rendered_component
      expect(page).to have_css('[data-testid="project-activity-timeline"]')
    end
  end

  context 'with a ticket status change' do
    let(:activity) do
      create(:activity, trackable: ticket, organisation:, actor: user, action: 'status_changed',
                        parameters: { 'from_status' => 'In Arbeit', 'to_status' => 'Abgenommen' },
                        created_at: Time.zone.local(2026, 9, 8, 9, 53))
    end
    let(:activities) { [activity] }

    it 'renders one quiet linked row with sentence, context, icon and mono time' do
      rendered_component

      expect(page).to have_content('08.09.2026 1', normalize_ws: true)
      expect(page).to have_css('span.line-through', text: 'In Arbeit')
      expect(page).to have_content('Abgenommen')
      expect(page).to have_content("Gabi Boyke · ##{ticket.number} Logo einsetzen", normalize_ws: true)
      expect(page).to have_link(href: organisation_project_ticket_path(organisation, project, ticket))
      expect(page).to have_css("a[data-controller='list-row'][data-list-row-frame-value='ticket_display_frame']")
      expect(page).to have_css("a[data-list-row-param-value='activity_id'][data-list-row-id-value='#{activity.id}']")
      expect(page).to have_css('i.bi-arrow-repeat')
      expect(page).to have_css('.font-mono', text: '09:53')
    end

    it 'does not render the legacy card, action link or foreign semantic colors' do
      rendered_component

      expect(page).not_to have_content('Anzeigen')
      expect(page).not_to have_css('.rounded-full')
      expect(page).not_to have_css('[class*="text-red-"]')
      expect(page).not_to have_css('[class*="text-green-"]')
      expect(page).not_to have_css('[class*="text-blue-"]')
      expect(page).not_to have_css('[class*="text-purple-"]')
      expect(page).not_to have_css('[class*="text-orange-"]')
    end
  end

  context 'with several changes to one ticket' do
    let(:base_time) { Time.zone.local(2026, 9, 2, 18, 29) }
    let(:activities) do
      %w[status_changed priority_changed title_changed].map.with_index do |action, index|
        create(:activity, trackable: ticket, organisation:, actor: user, action:,
                          parameters: { 'from_status' => 'Offen', 'to_status' => 'Fertig',
                                        'from_priority' => 'Low', 'to_priority' => 'Normal',
                                        'from_title' => 'Alt', 'to_title' => 'Neu' },
                          created_at: base_time + index.seconds)
      end.reverse
    end

    it 'renders the object cascade as one row that names its fields, with a disclosure' do
      rendered_component

      # Named, not counted (10.09.2026): "3 Änderungen zusammengefasst" made
      # every reader open the disclosure, so the grouping saved nothing.
      expect(page.find('section a')).to have_content('Status, Priorität und Titel geändert')
      expect(page).not_to have_content('zusammengefasst')
      expect(page).to have_css('summary', text: '3 Einzelschritte')
      expect(page).to have_css('section a', count: 1)
    end
  end

  # The drift this pins (10.09.2026): a long summary change rendered the whole
  # old text struck through and the whole new text in the row, and a
  # "Unterschied ansehen" disclosure below it with the same again.
  context 'with a long summary change' do
    let(:old_summary) do
      'Die erste Fassung beschreibt die **Modifikation** der Produktpflege auf eine einheitliche Technik.'
    end
    let(:new_summary) { 'Die zweite Fassung nennt dazu den Zeitplan, die Verantwortlichen und die offenen Punkte.' }
    let(:activity) do
      create(:activity, trackable: ticket, organisation:, actor: user, action: 'updated', key: 'ticket.updated',
                        attribute_changes: { 'summary' => [old_summary, new_summary] })
    end
    let(:activities) { [activity] }

    it 'names the field in the row and keeps both texts out of it' do
      rendered_component

      row = page.find("a[data-list-row-id-value='#{activity.id}']")
      expect(row).to have_content('Zusammenfassung geändert')
      expect(row).not_to have_content('Fassung')
      expect(page).not_to have_css('.line-through', visible: :all)
      expect(rendered_content).not_to include('**')
    end

    it 'shows before above after in the disclosure, labelled and typeset' do
      rendered_component

      details = page.find('details')
      expect(details).to have_css('summary', text: 'Unterschied ansehen')
      expect(details.all('dt', visible: :all).map { |term| term.text(:all).strip }).to eq(%w[vorher nachher])
      expect(details).to have_css('dd .md-preview strong', text: 'Modifikation', visible: :all)
      expect(details).to have_css('dd', text: 'Die zweite Fassung nennt dazu den Zeitplan', visible: :all)
    end
  end

  context 'with a long title changed twice in a row' do
    let(:first_title) { 'Produktpflege auf einheitliche Technik umstellen und dokumentieren' }
    let(:middle_title) { 'Produktpflege auf einheitliche Technik umstellen, dokumentieren, prüfen' }
    let(:last_title) { 'Produktpflege: einheitliche Technik, Dokumentation und Abnahme durch Kunde' }
    let(:activities) do
      [[first_title, middle_title], [middle_title, last_title]].map.with_index do |(from, to), index|
        create(:activity, trackable: ticket, organisation:, actor: user, action: 'title_changed',
                          parameters: { 'from_title' => from, 'to_title' => to },
                          created_at: Time.zone.local(2026, 9, 2, 18, 29) + index.minutes)
      end.reverse
    end

    it 'names the field and puts the net before and after above the steps' do
      rendered_component

      expect(page.find('section a')).to have_content('Titel geändert')
      details = page.find('details')
      expect(details).to have_css('summary', text: '2 Einzelschritte')
      expect(details.all('dd', visible: :all).map { |side| side.text(:all).strip }).to eq([first_title, last_title])
      expect(page).not_to have_css('.line-through', visible: :all)
    end
  end

  # Taken over from #801 (11.09.2026): several generic fields in one save name
  # themselves in one sentence, and the pairs wait in the disclosure.
  #
  # Reloaded on purpose: PostgreSQL's jsonb orders its keys by length, so the
  # row the app shows names "Titel" before "Zusammenfassung", whatever order
  # they were written in. Without the reload the record kept Ruby's order, and
  # the example asserted a sentence the app never shows.
  context 'with several generic changes at once' do
    let(:activity) do
      create(:activity, trackable: ticket, organisation:, actor: user, action: 'updated',
                        attribute_changes: { 'summary' => %w[Kurz Knapp], 'title' => %w[Alt Neu] }).reload
    end
    let(:activities) { [activity] }

    it 'names the fields in one sentence and lists the pairs in the disclosure' do
      rendered_component

      row = page.find("a[data-list-row-id-value='#{activity.id}']")
      expect(row).to have_content('Titel und Zusammenfassung geändert')
      expect(page).to have_css('details summary', text: 'Details anzeigen')
    end
  end

  # A bulk run is one line in the feed (doc/ticket_bulk_edit_plan.md, D12). It
  # fell back to Activity#message, the person's name first and the whole list
  # of changes after it (11.09.2026). The line counts the tickets now, and a
  # long list waits in the disclosure without "vorher" and "nachher": it is a
  # list, not a pair.
  context 'with a bulk change of several tickets' do
    let(:changes) do
      'Status auf „In Bearbeitung“ gesetzt, Priorität auf „Hoch“ gesetzt, Tags: +Frontend, +Relaunch'
    end
    let(:activity) do
      create(:activity, trackable: project, organisation:, actor: user, action: 'tickets_bulk_changed',
                        key: 'project.tickets_bulk_changed', parameters: { 'count' => 4, 'changes' => changes })
    end
    let(:activities) { [activity] }

    it 'counts the tickets in the line and lists the changes below it, as a list' do
      rendered_component

      row = page.find('section .group')
      expect(row.first('span.min-w-0 > span').text).to eq('4 Tickets geändert')
      expect(row).to have_css('details summary', text: 'Details anzeigen')
      expect(row.find('details', visible: :all).text(:all)).to include(changes)
      expect(row).not_to have_css('dt', visible: :all)
      expect(row).to have_css('i.bi-pencil')
    end
  end

  # Taken over from #801: a value is as often an identifier as it is prose. A
  # string column holds a name, so "waiting_for_customer" stays whole.
  context 'with a short change of an identifier' do
    let(:activity) do
      create(:activity, trackable: ticket, organisation:, actor: user, action: 'updated',
                        attribute_changes: { 'ticket_type' => %w[waiting_for_customer done] })
    end
    let(:activities) { [activity] }

    it 'keeps the identifier whole' do
      rendered_component

      row = page.find("a[data-list-row-id-value='#{activity.id}']")
      expect(row).to have_content('Typ')
      expect(row).to have_css('.line-through', text: 'waiting_for_customer')
    end
  end

  context 'with a project-scoped document event' do
    let(:document) { create(:document, project:, organisation:, creator: user) }
    let(:activity) do
      create(:activity, trackable: project, secondary: document, organisation:, actor: user,
                        action: 'document_created', key: 'project.document_created',
                        parameters: { 'document_title' => 'Baubeschreibung' })
    end
    let(:activities) { [activity] }

    it 'keeps the knowledge page as fallback but fetches the document endpoint into the lane' do
      rendered_component

      row = page.find("a[data-list-row-id-value='#{activity.id}']")
      expect(row[:href]).to eq(organisation_project_knowledge_index_path(organisation, project,
                                                                         type: 'document', document_id: document.id))
      expect(row['data-list-row-url-value']).to eq(organisation_project_document_path(organisation, project, document))
    end
  end

  context 'with a project-scoped note event whose object is gone' do
    let(:activity) do
      create(:activity, trackable: project, organisation:, actor: user, action: 'note_created',
                        key: 'project.note_created', parameters: { 'note_title' => 'Protokoll Kickoff' })
    end
    let(:activities) { [activity] }

    it 'uses the snapshot as context without inventing an object link' do
      rendered_component

      expect(page).to have_content('Notiz erstellt')
      expect(page).to have_content('Gabi Boyke · Protokoll Kickoff', normalize_ws: true)
      expect(page).not_to have_css('a[data-turbo-frame="_top"]')
    end
  end
end
