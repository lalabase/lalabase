# frozen_string_literal: true

require 'rails_helper'

# The token form's live summary ("This token will have access to: ...") is drawn by
# neo_personal_access_token_form_controller.js. Until 2026-10-02 it called
# this.organisationName(), which was never defined: ticking an organisation threw a
# TypeError and the summary stayed on its placeholder. Only a browser runs that code.
RSpec.describe 'Personal access token form', type: :system do
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation, name: 'Alpha GmbH') }
  let(:user) { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation),
                          active: true)
    end
  end

  before do
    sign_in user
    visit new_users_personal_access_token_path
  end

  def summary
    find('[data-neo-personal-access-token-form-target="summaryList"]')
  end

  it 'names a ticked organisation in the summary' do
    check 'Alpha GmbH'

    expect(summary).to have_text(I18n.t('stimulus.personal_access_token.all_projects', org: 'Alpha GmbH'))
  end

  it 'hides the organisation list and says "all organisations" when that option is chosen' do
    choose I18n.t('views.users.personal_access_tokens.new.org_mode_all')

    expect(page).to have_no_css('[data-neo-personal-access-token-form-target="organisationList"]', visible: :visible)
    expect(summary).to have_text(I18n.t('stimulus.personal_access_token.all_organisations'))
  end
end
