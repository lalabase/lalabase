# frozen_string_literal: true

require 'rails_helper'

# What: the one rule for who may read a comment, as a scope and as a predicate.
# Why: until 27.09.2026 the rule lived in PostPolicy#show? and in a narrower scope
#   (visible_to), and five readers (timeline, search, activity excerpt, summary, AI
#   answer) used neither. The scope and the predicate must agree, or a reader that
#   filters in SQL and one that filters in Ruby show different comments.
RSpec.describe Post, '.readable_by / #readable_by?', :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }
  let(:author) { create(:user) }
  let(:addressee) { create(:user) }
  let(:stranger) { create(:user) }
  let(:admin) { create(:user) }
  let(:inactive_admin) { create(:user) }

  let(:other_organisation) { create(:organisation) }
  let(:foreign_admin) { create(:user) }

  let(:public_post) { create(:post, ticket: ticket, user: author, is_private: false) }
  # The web composer's shape: private means "only for me"
  let(:note_to_self) { create(:post, ticket: ticket, user: author, is_private: true) }
  # The API's shape: private and addressed to someone else
  let(:addressed) { create(:post, ticket: ticket, user: author, is_private: true, visible_to_user: addressee) }

  # Setup only, paused: creating memberships and posts repeats the organisation lookup
  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause do
      admin_role = Role.find_or_create_account_admin(organisation)
      [author, addressee, stranger].each { |user| create(:membership, user: user, organisation: organisation) }
      create(:membership, user: admin, organisation: organisation, role: admin_role)
      create(:membership, user: inactive_admin, organisation: organisation, role: admin_role, active: false)
      ActsAsTenant.with_tenant(other_organisation) do
        create(:membership, user: foreign_admin, organisation: other_organisation,
                            role: Role.find_or_create_account_admin(other_organisation))
      end
      [public_post, note_to_self, addressed]
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def readable(user)
    described_class.readable_by(user, organisation).where(ticket: ticket).to_a
  end

  {
    author: %i[public_post note_to_self addressed],
    addressee: %i[public_post addressed],
    stranger: %i[public_post],
    admin: %i[public_post note_to_self addressed],
    inactive_admin: %i[public_post],
    foreign_admin: %i[public_post]
  }.each do |reader, expected|
    context "for the #{reader.to_s.tr('_', ' ')}" do
      it "reads exactly #{expected.join(', ')}" do
        user = public_send(reader)

        expect(readable(user)).to match_array(expected.map { |name| public_send(name) })
      end

      it 'agrees with the predicate on every post' do
        user = public_send(reader)
        posts = [public_post, note_to_self, addressed]

        expect(posts.select { |post| post.readable_by?(user) }).to match_array(readable(user))
      end
    end
  end

  it 'gives a reader without an account the public posts only' do
    expect(readable(nil)).to eq([public_post])
    expect([note_to_self, addressed].map { |post| post.readable_by?(nil) }).to eq([false, false])
  end

  # The admin branch returns every post of the organisation it is asked about, never
  # of another: the scope is also used outside a tenant block (jobs, the mailer)
  it "does not open another organisation's private posts to its admin" do
    foreign_private = Prosopite.pause do
      ActsAsTenant.with_tenant(other_organisation) do
        foreign_ticket = create(:ticket, project: create(:project, organisation: other_organisation),
                                         organisation: other_organisation)
        create(:post, ticket: foreign_ticket, user: foreign_admin, is_private: true)
      end
    end

    ActsAsTenant.without_tenant do
      expect(described_class.readable_by(admin, organisation)).not_to include(foreign_private)
    end
  end
end
