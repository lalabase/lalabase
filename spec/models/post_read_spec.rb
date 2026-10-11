# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostRead, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:post_record) do
    project = create(:project, organisation: organisation)
    ticket = create(:ticket, organisation: organisation, project: project)
    create(:post, organisation: organisation, ticket: ticket, user: user)
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  it 'requires a timestamp and stays unique per user and post' do
    create(:post_read, organisation: organisation, post: post_record, user: user)
    duplicate = build(:post_read, organisation: organisation, post: post_record, user: user)
    without_timestamp = build(:post_read, organisation: organisation, post: post_record, user: create(:user), read_at: nil)

    expect(duplicate).not_to be_valid
    expect(without_timestamp).not_to be_valid
  end

  it 'rejects an organisation that differs from the post' do
    read = PostRead.new(post: post_record, user: user, organisation: create(:organisation), read_at: Time.current)

    ActsAsTenant.without_tenant do
      expect(read).not_to be_valid
      expect(read.errors[:organisation]).to be_present
    end
  end

  it 'is removed with its post' do
    read = create(:post_read, organisation: organisation, post: post_record, user: user)

    post_record.destroy!

    expect(PostRead.unscoped.find_by(id: read.id)).to be_nil
  end
end
