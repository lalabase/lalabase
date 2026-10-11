# frozen_string_literal: true

require 'rails_helper'

RSpec.describe McpIdempotencyKey, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:pat) { create(:personal_access_token, user: user, organisations: [organisation]) }

  def build_key(**attrs)
    described_class.new({
      personal_access_token: pat,
      idempotency_key: 'k1',
      tool_name: 'create_ticket',
      request_fingerprint: 'fp'
    }.merge(attrs))
  end

  it 'is valid with the required attributes' do
    expect(build_key).to be_valid
  end

  it 'requires idempotency_key, tool_name and request_fingerprint' do
    expect(build_key(idempotency_key: nil)).not_to be_valid
    expect(build_key(tool_name: nil)).not_to be_valid
    expect(build_key(request_fingerprint: nil)).not_to be_valid
  end

  it 'scopes key uniqueness to the token' do
    build_key.save!
    dup = build_key
    expect(dup).not_to be_valid
    expect(dup.errors[:idempotency_key]).to be_present
  end

  it 'allows the same key for a different token' do
    build_key.save!
    other = create(:personal_access_token, user: user, organisations: [organisation])
    expect(build_key(personal_access_token: other)).to be_valid
  end
end
