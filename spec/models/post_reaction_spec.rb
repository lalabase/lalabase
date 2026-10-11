# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostReaction, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:post_record) do
    ActsAsTenant.with_tenant(organisation) do
      ticket = create(:ticket, organisation: organisation,
                               project: create(:project, organisation: organisation))
      create(:post, organisation: organisation, ticket: ticket, user: user)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  it 'allows each supported reaction once per user and post' do
    create(:post_reaction, organisation: organisation, post: post_record, user: user, emoji: '👍')
    duplicate = build(:post_reaction, organisation: organisation, post: post_record, user: user, emoji: '👍')

    expect(duplicate).not_to be_valid
    expect(build(:post_reaction, organisation: organisation, post: post_record, user: user, emoji: '🎉')).to be_valid
  end

  it 'rejects arbitrary reaction values' do
    reaction = build(:post_reaction, organisation: organisation, post: post_record, user: user, emoji: '🚫')

    expect(reaction).not_to be_valid
  end

  it 'rejects a reaction whose organisation differs from the post' do
    other_organisation = create(:organisation)
    reaction = PostReaction.new(post: post_record, user: user, organisation: other_organisation, emoji: '👍')

    ActsAsTenant.without_tenant do
      expect(reaction).not_to be_valid
      expect(reaction.errors[:organisation]).to be_present
    end
  end

  it 'is removed with its post' do
    reaction = create(:post_reaction, organisation: organisation, post: post_record, user: user)

    post_record.destroy!

    expect(PostReaction.unscoped.find_by(id: reaction.id)).to be_nil
  end
end
