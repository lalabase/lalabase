# frozen_string_literal: true

require 'rails_helper'

# What:  The button of the ticket list's first-use empty state ("Create ticket") opens
#        the writing surface, and the ticket saved there takes the empty state's place.
# Type:  System spec with headless Chrome. A request spec cannot see this: the markup
#        was complete, the click did nothing.
# Why:   In every release up to 2026.11.1 the button fired the action of a pop-up that
#        the writing surface had replaced (lalabase/lalabase#259). No element mounted
#        that controller any more, so Stimulus bound nothing: no request, no error, not
#        a line in the console. spec/architecture/stimulus_controller_wiring_spec.rb
#        knows that shape now, and only that shape. This one presses the button,
#        whatever it is wired with.
RSpec.describe 'First ticket from the empty list', type: :system do
  before { Prosopite.pause }
  after { Prosopite.resume }

  around do |example|
    adapter_was = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = adapter_was
  end

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let!(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:empty_title) { I18n.t('views.organisations.tickets.tickets_results.empty_first_time_title') }
  let(:button_label) { I18n.t('views.organisations.tickets.tickets_results.empty_first_time_cta') }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    end
    login_as(user, scope: :user)
  end

  def open_the_form_with_the_first_use_button
    visit organisation_project_tickets_path(organisation, project)
    within('#tickets_list_frame') do
      expect(page).to have_text(empty_title)
      click_on button_label
    end
    expect(page).to have_css('turbo-frame#writing_surface .writing-surface', wait: 10)
  end

  it 'opens the writing surface with the cursor in the title' do
    open_the_form_with_the_first_use_button

    expect(page).to have_css('.writing-surface input[name="ticket[title]"]:focus', wait: 5)
    # The form went into its own frame: the list behind it is still the list. A link
    # that forgot to name the frame would have put "Content missing" there.
    expect(page).to have_css('#tickets_list_frame', text: empty_title)
  end

  it 'saves the first ticket, and the list takes the place of the empty state' do
    open_the_form_with_the_first_use_button
    find('.writing-surface input[name="ticket[title]"]').fill_in(with: 'Erstes Ticket')
    find('.writing-surface button[type="submit"]').click

    expect(page).to have_no_css('.writing-surface', wait: 10)
    expect(page).to have_css('#tickets_list_frame tr[data-ticket-id]', text: 'Erstes Ticket', wait: 10)
    expect(page).to have_no_text(empty_title)
    expect(ActsAsTenant.with_tenant(organisation) { project.tickets.pluck(:title) }).to eq(['Erstes Ticket'])
  end
end
