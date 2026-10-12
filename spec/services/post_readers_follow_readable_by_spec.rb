# frozen_string_literal: true

require 'rails_helper'

# What: the readers that already filtered private comments (API ticket show and
#   attachments, MCP get_ticket through Tickets::Serializer, the assistant search
#   through CombinedSearchService) follow the same rule as the timeline:
#   Post.readable_by. The attachments list applies the rule in its controller,
#   so its examples are request specs:
#   spec/requests/api/v1/ticket_attachments_privacy_spec.rb.
# Why: they used Post.visible_to, which knows only the addressee. An author who
#   addressed a comment to someone else through the API lost it, and an account
#   admin saw private comments in the timeline but not in the API. One rule, one
#   answer on every surface.
RSpec.describe 'Readers of private comments', :ci_guard, type: :service do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:author) { create(:user) }
  let(:addressee) { create(:user) }
  let(:stranger) { create(:user) }
  let(:admin) { create(:user) }
  let(:addressed) do
    create(:post, ticket: ticket, user: author, is_private: true, visible_to_user: addressee,
                  content: 'addressed searchable remark')
  end

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause do
      [author, addressee, stranger].each do |user|
        create(:membership, user: user, organisation: organisation)
        create(:project_permission, user: user, project: project, tickets_access: :read_write)
      end
      create(:membership, user: admin, organisation: organisation,
                          role: Role.find_or_create_account_admin(organisation))
      create(:fragment, fragmentable: addressed, plain_text_content: 'addressed searchable remark',
                        organisation: organisation)
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  readers = { author: true, addressee: true, admin: true, stranger: false }

  describe 'Tickets::Serializer#full (API show, MCP get_ticket)' do
    readers.each do |reader, sees|
      it "#{sees ? 'includes' : 'leaves out'} the comment for the #{reader}" do
        post_ids = Tickets::Serializer.new(current_user: public_send(reader)).full(ticket)[:posts].pluck(:id)

        expect(post_ids.include?(addressed.id)).to be(sees)
      end
    end
  end

  describe 'CombinedSearchService (assistant search)' do
    readers.each do |reader, sees|
      it "#{sees ? 'finds' : 'does not find'} the comment for the #{reader}" do
        found = CombinedSearchService.new(organisation: organisation, query: 'searchable', embedding: nil,
                                          current_user: public_send(reader), project_id: project.id)
                                     .call.select { |fragment| fragment.fragmentable_type == 'Post' }
                                     .map(&:fragmentable)

        expect(found.include?(addressed)).to be(sees)
      end
    end
  end
end
