# frozen_string_literal: true

require 'rails_helper'

# What:  The Personal Access Tokens index page (Präferenzen › API-Tokens).
# Type:  Request spec against the real controller action (full stack).
# Why:   The page must ALWAYS show a plain-language explainer beside the token list so a
#        non-technical user immediately understands what tokens are for (external dev
#        tools like Claude Code) and — just as important — what they are NOT (not a login,
#        not an invite). Regression guard for the two-column explainer panel and the
#        clarified subtitle. The explainer shows regardless of whether tokens exist.
RSpec.describe 'Personal Access Tokens index explainer', type: :request do
  let(:user) { create(:user) }

  before { sign_in user }

  it 'renders the explainer heading, the "what this is NOT" box and the sharpened subtitle' do
    get users_personal_access_tokens_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t('views.users.personal_access_tokens.index.explainer.title'))
    expect(response.body).to include(I18n.t('views.users.personal_access_tokens.index.explainer.not_title'))
    expect(response.body).to include(I18n.t('views.users.personal_access_tokens.index.subtitle'))
  end
end
