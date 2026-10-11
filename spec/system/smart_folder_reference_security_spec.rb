# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Smart folder reference security', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:payload) { '"></option></select><img src=x onerror="window.referenceXss=true"><select><option>' }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end
  after { Prosopite.resume }

  def open_editor
    folder = create(:smart_folder, project: project, organisation: organisation, user: user, target_object_type: 'Ticket')
    visit edit_organisation_smart_folder_path(organisation, folder)
    expect(page).to have_css('[data-controller="smart-folder-form"]')
    wait_for_form_controller
    page.execute_script('window.referenceXss = false')
  end

  # The markup is there before its controller is. Stimulus loads the controllers one by
  # one AFTER the page's load event (eagerLoadControllersFrom), and `visit` returns at
  # that event. A field chosen in between fires a change nobody listens to, and the
  # operators never arrive. Until 2026-09-30 a large deferred script in the layout (the
  # editor removed with #946) held the load event back long enough to hide the race.
  def wait_for_form_controller
    page.document.synchronize do
      connected = page.evaluate_script(<<~JS)
        Boolean(window.Stimulus?.getControllerForElementAndIdentifier(
          document.querySelector('[data-controller~="smart-folder-form"]'), 'smart-folder-form'))
      JS
      raise Capybara::ExpectationNotMet, 'the smart folder form controller is not connected yet' unless connected
    end
  end

  def choose(field, operator)
    find("select[name$='[field]'] option[value='#{field}']").select_option
    find("select[name$='[operator]'] option[value='#{operator}']").select_option
  end

  it 'renders malicious user display names as literal option text after the API reload' do
    attacker = create(:user, first_name: payload, last_name: 'Literal')
    create(:membership, user: attacker, organisation: organisation, role: create(:role, organisation: organisation))
    open_editor
    choose('creator', 'equals')
    option = find("[data-smart-folder-form-target='referenceSelect'] option[value='#{attacker.id}']", visible: :all)
    expect(option.text(:all)).to include(payload)
    expect(page).not_to have_css('form img[src="x"]', visible: :all)
    expect(page.evaluate_script('window.referenceXss')).to be(false)
  end

  it 'preserves malicious custom option labels and values in selects and checkbox lists' do
    create(:ticket_attribute_definition, :select, project: project, name: 'unsafe_options',
                                                  options: { 'allowed_values' => [{ 'value' => payload, 'labels' => { 'de' => payload, 'en' => payload } }] })
    open_editor
    choose('custom_unsafe_options', 'equals')
    select = find('[data-smart-folder-form-target="valueContainer"] select')
    expect(select.all('option', visible: :all).last.text(:all)).to eq(payload)
    expect(select.all('option', visible: :all).last[:value]).to eq(payload)
    find('select[name$="[operator]"] option[value="in_list"]').select_option
    checkbox = find('[data-smart-folder-form-target="multiSelect"] input[type="checkbox"]')
    expect(checkbox[:value]).to eq(payload)
    expect(page).to have_css('[data-smart-folder-form-target="multiSelect"] span', text: payload)
    checkbox.check
    expect(find('[data-smart-folder-form-target="multiSelectHidden"]', visible: :all).value).to eq(payload)
    expect(page).not_to have_css('form img[src="x"]', visible: :all)
    expect(page.evaluate_script('window.referenceXss')).to be(false)
  end
end
