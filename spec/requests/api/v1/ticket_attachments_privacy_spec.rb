# frozen_string_literal: true

require 'rails_helper'

# What: GET /api/v1/tickets/:id/attachments lists the file of a private comment
#   only for the people Post.readable_by lets read that comment: its addressee,
#   its author and an account admin. Another member of the same project gets the
#   ticket's own file and a public comment's file from the same answer, so the
#   missing entry is the filter at work, not an empty or failed list.
# Why: the rule is applied in Api::V1::TicketsController#collect_attachments,
#   not in a serializer the service-level readers spec
#   (spec/services/post_readers_follow_readable_by_spec.rb) can call. Each answer
#   carries a signed download URL that needs no session, so a file listed here is
#   a file handed out.
RSpec.describe 'API ticket attachments of private comments', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:author) { create(:user) }
  let(:addressee) { create(:user) }
  let(:stranger) { create(:user) }
  let(:admin) { create(:user) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: author) }
  let(:public_comment) { create(:post, ticket: ticket, user: author, is_private: false) }
  let(:private_comment) { create(:post, ticket: ticket, user: author, is_private: true, visible_to_user: addressee) }

  before do
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        [author, addressee, stranger].each do |user|
          create(:membership, user: user, organisation: organisation)
          create(:project_permission, user: user, project: project, tickets_access: :read_write)
        end
        create(:membership, user: admin, organisation: organisation,
                            role: Role.find_or_create_account_admin(organisation))
        create(:ticket_document, ticket: ticket, organisation: organisation)
        create(:post_document, post: public_comment, organisation: organisation)
        create(:post_document, post: private_comment, organisation: organisation)
      end
    end
  end

  def listed_for(user)
    token = Prosopite.pause { create(:personal_access_token, user: user, organisations: [organisation], read_only: true) }
    get "/api/v1/tickets/#{ticket.id}/attachments", headers: { 'Authorization' => "Bearer #{token.token}" }
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body)['data'].map { |file| [file['attached_to'], file['parent_id']] }
  end

  { author: true, addressee: true, admin: true, stranger: false }.each do |reader, sees|
    it "#{sees ? 'lists' : 'leaves out'} the private comment's file for the #{reader}" do
      expected = [['ticket', nil], ['post', public_comment.id]]
      expected << ['post', private_comment.id] if sees

      expect(listed_for(public_send(reader))).to match_array(expected)
    end
  end
end
