# frozen_string_literal: true

require 'rails_helper'

# Taking a contact over into another organisation, in the browser, with real
# clicks: the dialog opens from the "···" menu of the card, Escape closes it
# and gives the focus back to "···", a same-named entry of the target asks
# first, "Trotzdem anlegen" creates once even on a double click, and the new
# person opens in the target with the notice naming the source.
RSpec.describe 'Taking a contact over into another organisation', :people_takeover, type: :system do
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Süd GmbH') }
  let(:reader) { takeover_join(takeover_join(create(:user), north, 'view_people'), south, 'manage_people') }
  let!(:source) { takeover_person(north, name: 'Herr Schmidt', function: 'Technik', notes: 'Nur vormittags erreichbar') }
  let(:menu_button) { "##{helper.person_more_actions_id(source.id)}" }
  let(:scope) { 'views.organisations.people.takeover' }

  before do
    Prosopite.pause
    sign_in reader
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  def open_dialog
    visit organisation_people_path(north, person_id: source.id)
    find("##{helper.person_more_actions_id(source.id)}").click
    click_link I18n.t("#{scope}.menu")
    expect(page).to have_css('[role="dialog"]', text: I18n.t("#{scope}.title"))
  end

  def helper
    Class.new { include PeopleHelper }.new
  end

  def copies_in_south
    ActsAsTenant.with_tenant(south) { Person.where(organisation: south).where(name: 'Herr Schmidt').count }
  end

  it 'opens from the menu and Escape closes it, with the focus back on "···"' do
    open_dialog
    expect(page).to have_select('target', selected: 'Süd GmbH')
    expect(page.evaluate_script('document.activeElement.name')).to eq('target')
    expect(page).to have_css('[role="dialog"] strong', text: 'Süd GmbH')
    expect(page).to have_unchecked_field(id: "#{helper.person_takeover_modal_id(source.id)}-field-notes")

    expect(page).to have_no_css('details.more-menu[open]')

    page.send_keys(:escape)

    expect(page).to have_no_css('[role="dialog"]')
    expect(page).to have_css('.people-detail', text: 'Herr Schmidt')
    # The focus comes back after the frame emptied (a timeout in the modal
    # controller): a retrying matcher, never one read of activeElement.
    expect(page).to have_css("#{menu_button}:focus")
    expect(page).to have_no_css('details.more-menu[open]')
  end

  it 'names the chosen target in the visibility sentence and drops a question asked for another target' do
    west = create(:organisation, name: 'West AG')
    takeover_join(reader, west, 'manage_people')
    takeover_person(south, name: 'Herr Schmidt')
    open_dialog

    click_button I18n.t("#{scope}.submit")
    expect(page).to have_css('[role="dialog"] [role="alert"]', text: 'Süd GmbH')
    expect(page).to have_button(I18n.t("#{scope}.confirm"))

    select 'West AG', from: 'target'

    expect(page).to have_css('[role="dialog"] strong', text: 'West AG')
    expect(page).to have_no_css('[role="dialog"] [role="alert"]')
    click_button I18n.t("#{scope}.submit")

    expect(page).to have_text(I18n.t('controllers.people.takeover.success', source: 'Nord GmbH'))
    expect(ActsAsTenant.with_tenant(west) { Person.where(organisation: west, name: 'Herr Schmidt').count }).to eq(1)
  end

  it 'asks about a same-named entry, creates once on a double click and opens the copy in the target' do
    takeover_person(south, name: 'Herr Schmidt', email: 'other@example.com')
    open_dialog

    click_button I18n.t("#{scope}.submit")
    expect(page).to have_css('[role="dialog"] [role="alert"]', text: 'Süd GmbH')
    expect(copies_in_south).to eq(1)

    find_button(I18n.t("#{scope}.confirm")).double_click

    expect(page).to have_text(I18n.t('controllers.people.takeover.success', source: 'Nord GmbH'))
    expect(page).to have_current_path(/\A#{Regexp.escape(organisation_people_path(south))}\?person_id=/, url: false)
    expect(page).to have_css('.people-detail', text: 'Technik')
    expect(page).to have_no_css('.people-note', text: 'Nur vormittags')
    expect(copies_in_south).to eq(2)
  end

  # The question offers to merge with the entry that is there already (People S2): a second
  # submit of the same form. Only a browser shows that Turbo sends the button that was
  # clicked, and that the button leaves with the question when the target changes.
  it 'merges with the same-named entry instead of creating a second one, and stays on the card' do
    existing = takeover_person(south, name: 'Herr Schmidt', email: 'other@example.com')
    west = create(:organisation, name: 'West AG')
    takeover_join(reader, west, 'manage_people')
    open_dialog
    click_button I18n.t("#{scope}.submit")
    merge = I18n.t("#{scope}.merge_instead", name: 'Herr Schmidt')
    expect(page).to have_css('[role="dialog"] [role="alert"]', text: 'Süd GmbH')
    expect(page).to have_button(merge)

    # The offer belongs to the target it was asked for.
    select 'West AG', from: 'target'
    expect(page).to have_no_button(merge)
    select 'Süd GmbH', from: 'target'

    click_button merge

    expect(page).to have_text(I18n.t('controllers.people.takeover.merged_instead'))
    expect(page).to have_current_path(organisation_people_path(north, person_id: source.id))
    expect(page).to have_no_css('[role="dialog"]')
    expect(copies_in_south).to eq(1)
    expect(PersonGroupEntry.where(owner_id: reader.id).pluck(:organisation_id, :person_id))
      .to contain_exactly([north.id, source.id], [south.id, existing.id])
  end

  # Enter in a field of the form sends the form through its FIRST submit button. The offers
  # to merge instead are submit buttons of the same form and stand above the main one, so
  # the form carries a default button of its own in front of them. This is Chrome's rule;
  # an older Safari takes the first button that is drawn, which the request spec holds in
  # the markup ("opens the form with a default button that is drawn", person_takeovers_spec.rb).
  describe 'Enter in the dialog' do
    let!(:existing) { takeover_person(south, name: 'Herr Schmidt', email: 'other@example.com') }
    let(:function_tick) { "##{helper.person_takeover_modal_id(source.id)}-field-function" }

    def groups
      PersonGroupEntry.where(owner_id: reader.id).pluck(:organisation_id, :person_id)
    end

    it 'creates anyway while the question is open, as the main button does, and merges with nobody else' do
      open_dialog
      click_button I18n.t("#{scope}.submit")
      expect(page).to have_button(I18n.t("#{scope}.merge_instead", name: 'Herr Schmidt'))

      find(function_tick).send_keys(:enter)

      expect(page).to have_text(I18n.t('controllers.people.takeover.success', source: 'Nord GmbH'))
      expect(page).to have_no_text(I18n.t('controllers.people.takeover.merged_instead'))
      expect(copies_in_south).to eq(2)
      expect(groups).not_to include([south.id, existing.id])
    end

    # Turbo disables the button that sent the form, and no other. Enter sends through the
    # default button nobody sees, so until 2026-11-17 "Trotzdem anlegen" and the offers to
    # merge stayed live while the request ran: a click on one of them sent the form a
    # second time and made a second copy. What the buttons were at the moment the request
    # started is read at that moment, by a listener above the dialog.
    it 'locks every button of the form while it is sent' do
      open_dialog
      click_button I18n.t("#{scope}.submit")
      expect(page).to have_button(I18n.t("#{scope}.merge_instead", name: 'Herr Schmidt'))
      page.execute_script(<<~JS)
        window.takeoverButtonsWhileSent = null
        document.addEventListener("turbo:submit-start", (event) => {
          window.takeoverButtonsWhileSent =
            Array.from(event.target.querySelectorAll('button[type="submit"]')).map((button) => button.disabled)
        }, { once: true })
      JS

      find(function_tick).send_keys(:enter)

      expect(page).to have_text(I18n.t('controllers.people.takeover.success', source: 'Nord GmbH'))
      expect(page.evaluate_script('window.takeoverButtonsWhileSent')).to eq([true, true, true])
      expect(copies_in_south).to eq(2)
    end

    it 'takes over into the target chosen after the question, not into the one the question was about' do
      west = create(:organisation, name: 'West AG')
      takeover_join(reader, west, 'manage_people')
      open_dialog
      click_button I18n.t("#{scope}.submit")
      expect(page).to have_button(I18n.t("#{scope}.merge_instead", name: 'Herr Schmidt'))
      select 'West AG', from: 'target'
      expect(page).to have_no_button(I18n.t("#{scope}.merge_instead", name: 'Herr Schmidt'))
      # A hidden offer cannot be sent either, whatever sends the form.
      expect(page).to have_css('button[name="merge_with"][disabled]', visible: :all)

      find(function_tick).send_keys(:enter)

      expect(page).to have_text(I18n.t('controllers.people.takeover.success', source: 'Nord GmbH'))
      expect(ActsAsTenant.with_tenant(west) { Person.where(organisation: west, name: 'Herr Schmidt').count }).to eq(1)
      expect(copies_in_south).to eq(1)
    end
  end
end
