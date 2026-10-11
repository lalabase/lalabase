# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Actors::SavePost, 'activity tracking' do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  describe 'when creating a new post' do
    let(:post_params) do
      {
        content: 'This is a new comment on the ticket',
        is_private: false
      }
    end

    it 'creates an activity for the new post' do
      expect do
        actor = described_class.new(ticket: ticket, params: post_params, id: nil, current_user: user)
        result = actor.call
        expect(result.success?).to be true
      end.to change(Activity, :count).by_at_least(1)

      activity = Activity.where(action: 'post_added').last
      expect(activity).to be_present
      expect(activity.trackable).to eq(ticket)
      expect(activity.secondary_type).to eq('Post')
      expect(activity.actor).to eq(user)
    end

    it 'stores only non-personal data in parameters' do
      actor = described_class.new(ticket: ticket, params: post_params, id: nil, current_user: user)
      result = actor.call
      expect(result.success?).to be true

      activity = Activity.where(action: 'post_added').last

      # Should NOT store author data
      expect(activity.parameters).not_to have_key('post_author')
      expect(activity.parameters).not_to have_key('author_name')

      # Should store content excerpt
      expect(activity.parameters['post_excerpt']).to eq('This is a new comment on the ticket')
      expect(activity.parameters['has_attachments']).to eq(false)
    end

    it 'tracks attachment status' do
      # Create a post without attachments first
      actor = described_class.new(ticket: ticket, params: post_params, id: nil, current_user: user)
      actor.call

      activity = Activity.where(action: 'post_added').last
      expect(activity.parameters['has_attachments']).to eq(false)
    end
  end

  describe 'when updating an existing post' do
    let(:existing_post) { create(:post, ticket: ticket, user: user, organisation: organisation) }
    let(:update_params) { { content: 'Updated content' } }

    it 'does not create an activity for updates' do
      expect do
        actor = described_class.new(ticket: ticket, params: update_params, id: existing_post.id, current_user: user)
        result = actor.call
        expect(result.success?).to be true
      end.not_to(change { Activity.where(action: 'post_added').count })
    end
  end

  describe 'GDPR compliance' do
    let(:post_params) { { content: 'Test comment' } }

    it 'allows post author anonymization' do
      # Create post and activity
      actor = described_class.new(ticket: ticket, params: post_params, id: nil, current_user: user)
      result = actor.call
      result.resource

      activity = Activity.where(action: 'post_added').last
      expect(activity.post_author_display_name).to eq(user.full_name)

      # Anonymize user
      user.update!(
        first_name: 'ANON',
        last_name: 'USER',
        email: "anon-#{user.id}@example.com"
      )

      # Reload to ensure we get fresh data
      user.reload
      activity.reload

      # Activity should show anonymized data
      expect(activity.post_author_display_name).to eq('ANON USER')
    end

    it 'handles deleted post authors gracefully' do
      # Create post
      actor = described_class.new(ticket: ticket, params: post_params, id: nil, current_user: user)
      result = actor.call
      result.resource

      activity = Activity.where(action: 'post_added').last

      # Delete the post (which would normally cascade delete the activity too)
      # But let's simulate a scenario where the user is deleted but post remains
      allow(activity.secondary).to receive(:user).and_return(nil)

      expect(activity.post_author_display_name).to eq('Gelöschter Nutzer')
    end
  end
end
