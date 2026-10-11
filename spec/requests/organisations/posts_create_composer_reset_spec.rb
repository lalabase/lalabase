# frozen_string_literal: true

require 'rails_helper'

# What:  posts#create answers a saved comment with a stream that replaces the comment
#        composer (new-post-composer-<ticket id>) by a FRESH one: collapsed, empty
#        editor, and a CREATE form - not an update form for the saved comment.
# Type:  Request spec (bug 24.08.2026; browser side in
#        spec/system/ticket_comment_composer_spec.rb).
# Why:   Nothing else closes the composer, and the form partial falls back to @post
#        (the just-saved comment) when it gets no post - the reset once came back
#        pre-filled and pointing at PATCH /posts/:id.
RSpec.describe 'Posts create: composer reset', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end
  let(:ticket) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, organisation: organisation, creator: user, title: 'T', content: '<div>x</div>')
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end
  after { ActsAsTenant.current_tenant = nil }

  it 'streams a fresh, collapsed create-composer after saving a comment' do
    post organisation_project_ticket_posts_path(organisation, project, ticket),
         params: { post: { content: '<div>Erster Kommentar</div>' } },
         headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

    expect(response).to have_http_status(:ok)
    stream = Nokogiri::HTML.fragment(response.body)
                           .at_css(%(turbo-stream[action="replace"][target="new-post-composer-#{ticket.id}"]))
    expect(stream).to be_present

    composer = stream.at_css('template').inner_html
    expect(composer).not_to include('Erster Kommentar')

    form = Nokogiri::HTML.fragment(composer).at_css('form')
    expect(form['action']).to eq(organisation_project_ticket_posts_path(organisation, project, ticket))
    expect(Nokogiri::HTML.fragment(composer).at_css('input[name="_method"]')).to be_nil
  end
end
