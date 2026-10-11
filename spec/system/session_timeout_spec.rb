# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Session expiry with an open ticket comment', type: :system do
  before { Prosopite.pause }
  after { Prosopite.resume }

  around do |example|
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, password: 'Password123!') }
  let!(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let!(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, title: 'Offener Entwurf')
    end
  end

  before do
    page.current_window.resize_to(1440, 900)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    end
    login_as(user, scope: :user)
  end

  it 'blocks a signed-out tab, preserves the draft and saves it after signing back in' do
    visit organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)
    composer = "#new-post-composer-#{ticket.id}"
    within(composer) { click_on 'Kommentar' }
    editor = "#{composer} lexxy-editor[name='post[content]'] .lexxy-editor__content"
    find(editor).send_keys('Dieser Entwurf bleibt erhalten')

    # Another tab signing out changes the shared cookie without navigating this page.
    page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      fetch(#{destroy_user_session_path.to_json}, {
        method: 'DELETE', headers: { 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '' }
      }).then(() => done());
    JS
    page.execute_script("window.dispatchEvent(new Event('focus'))")

    expect(page).to have_content('Du bist nicht mehr eingeloggt')
    expect(page).to have_current_path(organisation_project_tickets_path(organisation, project, ticket_id: ticket.id))
    # Native modal focus protection also prevents keyboard editing and Escape dismissal.
    page.execute_script("document.querySelector(#{editor.to_json}).focus()")
    expect(page.evaluate_script("document.activeElement.closest('dialog') !== null")).to be(true)
    page.execute_script(<<~JS)
      window.sessionTestEscaped = false;
      window.addEventListener('keydown', event => {
        if (event.key === 'Escape') window.sessionTestEscaped = true;
      });
    JS
    page.driver.browser.action.send_keys(:escape).perform
    expect(page.evaluate_script('window.sessionTestEscaped')).to be(false)
    expect(page).to have_css('dialog[open]')
    expect(page.evaluate_script("document.querySelector(#{editor.to_json}).innerText")).to include('Dieser Entwurf bleibt erhalten')

    login_window = window_opened_by { click_on 'In neuem Tab anmelden' }
    within_window(login_window) do
      fill_in 'user[email]', with: user.email
      fill_in 'user[password]', with: 'Password123!'
      find('input[type="submit"], button[type="submit"]').click
      expect(page).to have_no_field('user[password]', wait: 10)
    end
    page.execute_script("window.dispatchEvent(new Event('focus'))")
    expect(page).to have_no_css('dialog[open]', wait: 10)
    expect(find(editor).text).to include('Dieser Entwurf bleibt erhalten')
    within(composer) { find('button[type="submit"]').click }
    expect(page).to have_css("#{composer} [data-collapse-target='button']:not(.hidden)", wait: 10)
    expect(page).to have_content('Dieser Entwurf bleibt erhalten')
  end

  it 'treats a redirected login page as a failed save so success handlers keep the draft' do
    visit organisation_project_tickets_path(organisation, project, ticket_id: ticket.id)
    composer = "#new-post-composer-#{ticket.id}"
    within(composer) { click_on 'Kommentar' }
    editor = "#{composer} lexxy-editor[name='post[content]'] .lexxy-editor__content"
    find(editor).send_keys('Nicht erfolgreich gespeichert')

    # Exercise the real Turbo response/submit-end sequence; a login redirect
    # ultimately returns HTTP 200, which otherwise looks like a successful save.
    page.execute_script(<<~JS)
      const form = document.querySelector(#{composer.to_json}).querySelector('form');
      form.addEventListener('turbo:submit-end', event => {
        window.sessionTestSubmitSuccess = event.detail.success;
        if (event.detail.success) form.reset();
      });
    JS
    allow_any_instance_of(Organisations::PostsController).to receive(:create) do |controller|
      controller.send(:skip_authorization)
      controller.sign_out(:user)
      controller.redirect_to new_user_session_path
    end
    within(composer) { find('button[type="submit"]').click }
    expect(page).to have_content('Du bist nicht mehr eingeloggt')
    expect(page.evaluate_script('window.sessionTestSubmitSuccess')).to be(false)
    expect(page.evaluate_script("document.querySelector(#{editor.to_json}).innerText")).to include('Nicht erfolgreich gespeichert')
  end
end
