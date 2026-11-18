# frozen_string_literal: true

require 'rails_helper'

# What: merging and splitting on the people list above the organisations
#       (POST /people/merges, DELETE /people/merges/:id) and what the list shows afterwards.
# Why:  a merge is a note that reaches over organisations, kept by ids a request sends.
#       Pinned here: a reference is not a right (a group never shows what the reader may
#       not read just now, and loses nothing for it), one answer for everything the reader
#       cannot name, and neither request moves the session's organisation or leaves a
#       tenant behind.
RSpec.describe 'Merging people above the organisations', :ci_guard, type: :request do
  include AllPeopleHelpers

  let(:user) { create(:user, first_name: 'Vera', last_name: 'Viewer', email: 'vera@example.com') }
  let(:stranger) { create(:user, email: 'fremd@example.com') }
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }
  let(:east) { create(:organisation, name: 'Ost eG') }

  let!(:people) do
    Prosopite.pause do
      join_organisation(user, south, admin: true)
      join_organisation(user, north, admin: true)
      join_organisation(stranger, east, admin: true)
      {
        north: person_in(north, name: 'Kai Kontakt', function: 'Einkauf', company: 'Nordlicht AG'),
        south: person_in(south, name: 'Kai Kontakt (Sued)', function: 'Vertrieb', company: 'Suedwind AG'),
        other: person_in(south, name: 'Sina Sued'),
        east: person_in(east, name: 'Olga Ost')
      }
    end
  end

  before { sign_in user }

  after { ActsAsTenant.current_tenant = nil }

  def source(person)
    "#{person.organisation_id}/person:#{person.id}"
  end

  def merge(*rows, **params)
    post all_people_merges_path, params: { rows: rows, **params }
  end

  def page(**params)
    get all_people_path(**params)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def rows(doc)
    doc.css('tr[data-all-people-row]')
  end

  def row_of(doc, name)
    rows(doc).find { |row| row.at_css('.all-people-row__name').text.strip == name }
  end

  def chips(row)
    row.css('[data-organisation-chip]').map { |chip| chip.text.strip }
  end

  def shown(doc)
    rows(doc).to_h { |row| [row.at_css('.all-people-row__name').text.strip, chips(row)] }
  end

  def answer
    [response.status, response.headers['Location'], flash[:alert], flash[:notice], response.body]
  end

  def stored
    [PersonGroup.count, PersonGroupEntry.count]
  end

  # The list itself. The frame of the page around it names the reader's organisations
  # (the menu of the sidebar), whatever right they hold there.
  def list_html(doc)
    doc.at_css('[data-all-people]').to_html
  end

  describe 'merging' do
    it 'makes two rows of two organisations one row with two chips, for the reader' do
      expect(shown(page)).to include('Kai Kontakt' => ['Nord GmbH'], 'Kai Kontakt (Sued)' => ['Sued AG'])

      merge(source(people[:north]), source(people[:south]))

      expect(response).to redirect_to(all_people_path)
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq(I18n.t('controllers.people.merge.success'))
      doc = page
      expect(shown(doc)).to include('Kai Kontakt' => ['Nord GmbH', 'Sued AG'])
      expect(shown(doc)).not_to have_key('Kai Kontakt (Sued)')
      expect(doc.at_css('[data-all-people-count]').text).to eq(I18n.t('views.all_people.count', count: 3))
    end

    it 'shows the merge to its owner alone' do
      colleague = create(:user, first_name: 'Karl', last_name: 'Kollege')
      Prosopite.pause { [north, south].each { |organisation| join_organisation(colleague, organisation, rights: ['view_people']) } }
      merge(source(people[:north]), source(people[:south]))

      sign_in colleague

      expect(shown(page)).to include('Kai Kontakt' => ['Nord GmbH'], 'Kai Kontakt (Sued)' => ['Sued AG'])
    end

    it 'takes a ticked row that stands for several organisations as all of its sources' do
      shared = create(:user, first_name: 'Mara', last_name: 'Mitglied')
      Prosopite.pause { [north, south].each { |organisation| join_organisation(shared, organisation) } }
      doc = page
      tick = row_of(doc, 'Mara Mitglied').at_css('input[type="checkbox"][name="rows[]"]')

      expect(tick['value']).to eq("#{north.id}/member:#{shared.id},#{south.id}/member:#{shared.id}")
      expect(tick['form']).to eq('all-people-merge')

      # A person who is in north already cannot take a second row of north.
      merge(tick['value'], source(people[:north]))

      expect(flash[:alert]).to eq(I18n.t('controllers.people.merge.same_organisation'))
      expect(stored).to eq([0, 0])
    end

    it 'goes back to the list the reader was looking at' do
      merge(source(people[:north]), source(people[:south]), q: 'kai', org: '', page: '3')

      expect(response).to redirect_to(all_people_path(q: 'kai', page: '3'))
    end

    # The bar hands the card open beside the list along (data-lane-keep): the merge comes
    # back to the list with that card still open.
    it 'goes back with the card that was open' do
      open = "#{north.id}:person:#{people[:north].id}"
      merge(source(people[:north]), source(people[:south]), q: 'kai', card: open)

      expect(response).to redirect_to(all_people_path(q: 'kai', card: open))
    end

    # A page travels only as a whole number from 2 to six digits: the first page is the
    # list without one, and nothing longer can be a page of this list.
    { '2' => '2', '123456' => '123456', '1' => nil, '0' => nil, '007' => nil, '1234567' => nil, '-2' => nil }
      .each do |sent, kept|
      it "carries the page #{sent.inspect} back as #{kept.inspect}" do
        merge(source(people[:north]), source(people[:south]), page: sent)

        expect(response).to redirect_to(all_people_path(page: kept))
      end
    end

    it 'keeps only a list state that is one: no address of another page, no list in place of a text' do
      merge(source(people[:north]), source(people[:south]), q: ['kai'], org: { id: north.id }, page: '//example.com')

      expect(response).to redirect_to(all_people_path)
    end
  end

  describe 'the bar and the ticks of the list' do
    it 'draws a tick per row that belongs to the form of the bar, and the bar posts to the merge' do
      doc = page
      form = doc.at_css('form#all-people-merge')

      expect(form['action']).to eq(all_people_merges_path)
      expect(form['method']).to eq('post')
      expect(form['data-turbo-frame']).to eq('_top')
      expect(rows(doc).size).to eq(4)
      expect(rows(doc).map { |row| row.at_css('input[name="rows[]"]')['form'] }.uniq).to eq(['all-people-merge'])
      expect(row_of(doc, 'Kai Kontakt').at_css('input[name="rows[]"]')['value']).to eq(source(people[:north]))
      expect(form.at_css('button[type="submit"]').text.strip).to eq(I18n.t('views.all_people.merge.submit'))
    end

    it 'carries the list state of the page in the form' do
      form = page(q: 'kai').at_css('form#all-people-merge')

      expect(form.at_css('input[name="q"]')['value']).to eq('kai')
    end

    # The card opens and changes in the address only, so the form cannot be drawn with it:
    # it asks layout-toggle for the card open now as it leaves. So does the organisation
    # select, a list filter that does not close the card.
    it 'marks the bar and the organisation select to take the open card along' do
      doc = page

      expect(doc.at_css('form#all-people-merge')['data-lane-keep']).to eq('true')
      expect(doc.at_css('form[data-all-people-tool="organisation"]')['data-lane-keep']).to eq('true')
    end

    it 'offers "Zusammenführung aufheben" on a merged row only' do
      merge(source(people[:north]), source(people[:south]))
      doc = page
      menu = row_of(doc, 'Kai Kontakt').at_css('form[action^="/people/merges/"]')

      expect(menu['action']).to eq(all_people_merge_path(PersonGroup.sole.id))
      expect(menu.at_css('input[name="_method"]')['value']).to eq('delete')
      expect(menu['data-turbo-confirm']).to eq(I18n.t('views.confirm.split_merged_person', name: 'Kai Kontakt'))
      expect(doc.css('form[action^="/people/merges/"]').size).to eq(1)
    end

    # Members with one account are one row without a merge: there is nothing to take apart.
    it 'offers no split for a person the account rule joins' do
      doc = page

      expect(chips(row_of(doc, 'Vera Viewer'))).to eq(['Nord GmbH', 'Sued AG'])
      expect(row_of(doc, 'Vera Viewer').at_css('form[action^="/people/merges/"]')).to be_nil
    end
  end

  describe 'splitting' do
    before { merge(source(people[:north]), source(people[:south])) }

    it 'restores the two rows' do
      delete all_people_merge_path(PersonGroup.sole.id)

      expect(response).to redirect_to(all_people_path)
      expect(flash[:notice]).to eq(I18n.t('controllers.people.split.success'))
      expect(stored).to eq([0, 0])
      expect(shown(page)).to include('Kai Kontakt' => ['Nord GmbH'], 'Kai Kontakt (Sued)' => ['Sued AG'])
    end

    it 'answers the group of another person and a missing id alike, and deletes nothing' do
      foreign = create(:person_group, owner: stranger)
      create(:person_group_entry, person_group: foreign, organisation: east, person_id: people[:east].id)
      # The notice of the merge above is shown once and gone.
      page

      answers = Prosopite.pause do
        [foreign.id, SecureRandom.uuid, 'oops'].map do |id|
          expect { delete all_people_merge_path(id) }.not_to(change { stored })
          answer
        end
      end

      expect(answers.uniq.size).to eq(1), answers.inspect
      expect(answers.first[0..2]).to eq([303, all_people_url, I18n.t('controllers.people.not_found')])
    end
  end

  # The card of a merged person takes the merge apart as well: the whole of it, or one
  # source of three or more. Both come back to the card.
  describe 'splitting from the card' do
    let(:west) { create(:organisation, name: 'West KG') }
    let(:west_person) { person_in(west, name: 'Kai Kontakt (West)') }
    let(:card) { "#{people[:north].organisation_id}:person:#{people[:north].id}" }

    before do
      Prosopite.pause { join_organisation(user, west, admin: true) }
      merge(source(people[:north]), source(people[:south]), source(west_person))
      # The notice of the merge is shown once and gone.
      page
    end

    def card_address(person)
      "#{person.organisation_id}:person:#{person.id}"
    end

    it 'takes one source out, keeps the others merged and comes back to the card' do
      delete all_people_merge_path(PersonGroup.sole.id), params: { source: card_address(people[:south]), card: card }

      expect(response).to redirect_to(all_people_path(card: card))
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq(I18n.t('controllers.people.split.source_success'))
      expect(stored).to eq([1, 2])
      expect(shown(page)).to include('Kai Kontakt' => ['Nord GmbH', 'West KG'], 'Kai Kontakt (Sued)' => ['Sued AG'])
    end

    # The card's own button for the first source names another source as the way back: the
    # reader took the north out and sees the person that stays merged, not the north alone.
    it 'comes back to the card of the people who stay merged when the first source leaves' do
      get all_people_path(card: card), headers: { 'Turbo-Frame' => AllPeopleController::CARD_FRAME_ID }
      form = Nokogiri::HTML(response.body).css('form[data-card-detach]').first
      expect(form.at_css('button').text.strip).to eq(I18n.t('views.all_people.card.detach', organisation: 'Nord GmbH'))

      delete form['action']

      expect(response).to have_http_status(:see_other)
      get response.headers['Location'], headers: { 'Turbo-Frame' => AllPeopleController::CARD_FRAME_ID }
      sources = Nokogiri::HTML(response.body).css('[data-card-source] .organisation-chip__name').map { |name| name.text.strip }
      expect(sources).to eq(['Sued AG', 'West KG'])
      expect(stored).to eq([1, 2])
    end

    it 'takes the whole merge apart without a source and comes back to the card' do
      delete all_people_merge_path(PersonGroup.sole.id), params: { card: card, q: 'kai' }

      expect(response).to redirect_to(all_people_path(q: 'kai', card: card))
      expect(flash[:notice]).to eq(I18n.t('controllers.people.split.success'))
      expect(stored).to eq([0, 0])
    end

    it 'answers a source it cannot take out like a missing merge, and deletes nothing' do
      answers = Prosopite.pause do
        [{ source: card_address(people[:other]) }, { source: card_address(people[:east]) }, { source: 'oops' },
         { source: "#{north.id}:person:#{SecureRandom.uuid}" }].map do |params|
          expect { delete all_people_merge_path(PersonGroup.sole.id), params: params }.not_to(change { stored })
          answer
        end
      end
      expect { delete all_people_merge_path(SecureRandom.uuid) }.not_to(change { stored })

      expect(answers.uniq.size).to eq(1), answers.inspect
      expect(answers.first).to eq(answer)
      expect(answers.first[0..2]).to eq([303, all_people_url, I18n.t('controllers.people.not_found')])
    end

    it 'takes a list or a hash in place of the source for no source at all: nothing half done' do
      expect { delete all_people_merge_path(PersonGroup.sole.id), params: { source: [card_address(people[:south])] } }
        .not_to(change { stored })

      expect(flash[:alert]).to eq(I18n.t('controllers.people.not_found'))
    end

    it 'keeps only a card address that is a text for the way back' do
      delete all_people_merge_path(PersonGroup.sole.id), params: { card: ['x'] }

      expect(response).to redirect_to(all_people_path)
    end

    it 'explains a refused regrouping and keeps the card and list context' do
      message = I18n.t('controllers.people.split.conflict')
      refusal = Actors::BaseActor::Result.new(success: false, code: :conflict, errors: [message])
      allow(Actors::SplitPerson).to receive(:call).and_return(refusal)

      delete all_people_merge_path(PersonGroup.sole.id), params: { source: card_address(people[:south]), card: card, q: 'kai', page: 2 }

      expect(response).to redirect_to(all_people_path(card: card, q: 'kai', page: 2))
      expect(flash[:alert]).to eq(message)
      expect(flash[:notice]).to be_nil
      expect(stored).to eq([1, 3])
    end
  end

  describe 'one answer for every entry the reader cannot name' do
    let(:hidden) { create(:organisation, name: 'Ohne Recht GmbH') }
    let!(:hidden_row) do
      Prosopite.pause do
        join_organisation(user, hidden)
        person_in(hidden, name: 'Kai Kontakt')
      end
    end

    it 'answers an invisible, a foreign and a missing entry with the same status and body, and writes nothing' do
      unknown = {
        invisible: source(hidden_row),
        foreign: source(people[:east]),
        missing: "#{south.id}/person:#{SecureRandom.uuid}",
        missing_organisation: "#{SecureRandom.uuid}/person:#{people[:south].id}",
        malformed: 'oops'
      }

      answers = Prosopite.pause do
        unknown.transform_values do |row|
          expect { merge(source(people[:north]), row) }.not_to(change { stored })
          answer
        end
      end

      expect(answers.values.uniq.size).to eq(1), answers.inspect
      expect(answers[:missing][0..3]).to eq([303, all_people_url, I18n.t('controllers.people.not_found'), nil])
      # The same request with a row the reader sees is taken.
      expect { merge(source(people[:north]), source(people[:south])) }.to change { stored }.to([1, 2])
    end

    it 'refuses fewer than two rows and writes nothing' do
      expect { merge(source(people[:north])) }.not_to(change { stored })
      expect(flash[:alert]).to eq(I18n.t('controllers.people.merge.too_few'))

      post all_people_merges_path
      expect(flash[:alert]).to eq(I18n.t('controllers.people.merge.too_few'))
    end

    # A row that stands for several organisations sends several sources. Until 2026-11-17
    # the sources were counted, not the rows: ONE ticked row of a member of two
    # organisations (or of an earlier merge) passed, nothing was written, and the answer
    # said "merged". Without the script nothing stops the button under two rows.
    it 'refuses one row that stands for two organisations, as it refuses any single row' do
      value = row_of(page, 'Vera Viewer').at_css('input[name="rows[]"]')['value']
      expect(value.split(',').size).to eq(2)

      expect { merge(value) }.not_to(change { stored })

      expect(flash[:notice]).to be_nil
      expect(flash[:alert]).to eq(I18n.t('controllers.people.merge.too_few'))
    end

    it 'refuses the one row of an earlier merge the same way, and keeps the merge' do
      merge(source(people[:north]), source(people[:south]))
      value = row_of(page, 'Kai Kontakt').at_css('input[name="rows[]"]')['value']
      expect(value.split(',').size).to eq(2)

      expect { merge(value) }.not_to(change { stored })

      expect(flash[:notice]).to be_nil
      expect(flash[:alert]).to eq(I18n.t('controllers.people.merge.too_few'))
    end

    it 'takes a row of two organisations together with a second row' do
      western = Prosopite.pause do
        mara = create(:user, first_name: 'Mara', last_name: 'Mitglied')
        [north, south].each { |organisation| join_organisation(mara, organisation) }
        west = create(:organisation, name: 'West KG')
        join_organisation(user, west, admin: true)
        person_in(west, name: 'Wanda West')
      end
      value = row_of(page, 'Mara Mitglied').at_css('input[name="rows[]"]')['value']
      expect(value.split(',').size).to eq(2)

      expect { merge(value, source(western)) }.to change { stored }.to([1, 3])
      expect(flash[:notice]).to eq(I18n.t('controllers.people.merge.success'))
    end
  end

  # Outside production an actor raises what it did not expect. In production it answers
  # with the message of the exception, and both actions put that into the flash: the text
  # of the database, with its process ids and its statement, on the page.
  describe 'a failure nobody wrote a text for' do
    let(:detail) { 'PG::TRDeadlockDetected: ERROR: deadlock detected DETAIL: Process 4711 waits for ShareLock' }

    before do
      allow_any_instance_of(Actors::BaseActor).to receive(:raise_unexpected?).and_return(false)
      allow(Rails.logger).to receive(:error)
    end

    it 'answers a merge with one sentence of ours and writes nothing' do
      allow(PersonGroup).to receive(:lock_for).and_raise(ActiveRecord::Deadlocked, detail)

      expect { merge(source(people[:north]), source(people[:south])) }.not_to(change { stored })

      expect(response).to redirect_to(all_people_path)
      expect(flash[:alert]).to eq(I18n.t('controllers.people.merge.failed'))
    end

    it 'answers a split the same way and keeps the merge' do
      merge(source(people[:north]), source(people[:south]))
      allow(PersonGroup).to receive(:lock_for).and_raise(ActiveRecord::Deadlocked, detail)

      expect { delete all_people_merge_path(PersonGroup.sole.id) }.not_to(change { stored })

      expect(response).to redirect_to(all_people_path)
      expect(flash[:alert]).to eq(I18n.t('controllers.people.split.failed'))
    end

    it 'still names the refusals the actor wrote a text for' do
      merge(source(people[:north]))

      expect(flash[:alert]).to eq(I18n.t('controllers.people.merge.too_few'))
    end
  end

  describe 'a reference is not a right' do
    before { merge(source(people[:north]), source(people[:south])) }

    def expect_north_alone
      doc = page

      expect(shown(doc)).to include('Kai Kontakt' => ['Nord GmbH'], 'Vera Viewer' => ['Nord GmbH'])
      expect(shown(doc).keys).to eq(['Kai Kontakt', 'Vera Viewer'])
      expect(list_html(doc)).to include('Nord GmbH', 'Nordlicht AG')
      expect(list_html(doc)).not_to include('Sued AG', 'Suedwind', 'Kai Kontakt (Sued)', 'Sina Sued', people[:south].id, south.id)
      expect(doc.css('form[action^="/people/merges/"]')).to be_empty
    end

    it 'shows nothing of an organisation whose people right was taken away, and keeps the group' do
      group = PersonGroup.sole
      Prosopite.pause { take_people_right(user, south) }

      expect_north_alone
      expect(PersonGroup.sole).to eq(group)
      expect(PersonGroupEntry.where(person_group_id: group.id).pluck(:organisation_id)).to contain_exactly(north.id, south.id)

      Prosopite.pause do
        ActsAsTenant.with_tenant(south) do
          role = create(:role, organisation: south)
          create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)
          Membership.find_by!(user: user, organisation: south).update!(role: role)
        end
      end

      expect(shown(page)).to include('Kai Kontakt' => ['Nord GmbH', 'Sued AG'])
    end

    it 'shows nothing of an organisation whose membership was deactivated, and keeps the group' do
      membership = Membership.find_by!(user: user, organisation: south)
      membership.update!(active: false)
      # With one organisation left the list above them is that organisation's own page.
      Prosopite.pause { join_organisation(user, east, rights: ['view_people']) }

      doc = page
      expect(shown(doc)).to include('Kai Kontakt' => ['Nord GmbH'])
      expect(list_html(doc)).not_to include('Sued AG', 'Suedwind', 'Kai Kontakt (Sued)', people[:south].id, south.id)
      expect(row_of(doc, 'Kai Kontakt').at_css('form[action^="/people/merges/"]')).to be_nil
      expect(stored).to eq([1, 2])

      membership.update!(active: true)

      expect(shown(page)).to include('Kai Kontakt' => ['Nord GmbH', 'Sued AG'])
    end

    it 'cannot merge a hidden part further: the entry of the lost organisation is unknown' do
      Prosopite.pause { take_people_right(user, south) }

      expect { merge(source(people[:north]), source(people[:other])) }.not_to(change { stored })
      expect(flash[:alert]).to eq(I18n.t('controllers.people.not_found'))
    end
  end

  describe 'the session and the tenant' do
    it 'leaves the organisation of the session where it was, and no tenant behind' do
      get organisation_people_path(north)
      expect(session[:current_organisation_id]).to eq(north.id)

      merge(source(people[:north]), source(people[:south]))
      expect(session[:current_organisation_id]).to eq(north.id)
      expect(ActsAsTenant.current_tenant).to be_nil

      merge(source(people[:north]), source(people[:east]))
      expect(session[:current_organisation_id]).to eq(north.id)
      expect(ActsAsTenant.current_tenant).to be_nil

      delete all_people_merge_path(PersonGroup.sole.id)
      expect(session[:current_organisation_id]).to eq(north.id)
      expect(ActsAsTenant.current_tenant).to be_nil

      delete all_people_merge_path(SecureRandom.uuid)
      expect(session[:current_organisation_id]).to eq(north.id)
      expect(ActsAsTenant.current_tenant).to be_nil
    end

    it 'needs a signed-in person' do
      sign_out user

      merge(source(people[:north]), source(people[:south]))

      expect(response).to redirect_to(new_user_session_path)
      expect(stored).to eq([0, 0])
    end
  end
end
