# frozen_string_literal: true

require 'rails_helper'

# What: the single-use token of the login hand-off between hosts
#   (doc/org_subdomains_plan.md, S3).
# Why: it signs a person in. It must count once, briefly, on one host, and only in the
#   browser that began it; a path must never become an address elsewhere.
RSpec.describe Sessions::HostHandoff do
  let(:user) { create(:user) }
  let(:host) { 'kunde.example.test' }
  let(:state) { 'browser-state' }

  def mint(**overrides)
    described_class.mint(user: user, host: host, path: '/org/x/tickets?view=list',
                         state_digest: described_class.digest(state), **overrides)
  end

  def claim(token, claim_host: host, claim_state: state)
    described_class.claim(token: token, host: claim_host, state: claim_state)
  end

  it 'gives the user and the path once' do
    token = mint

    expect(claim(token)).to have_attributes(user: user, path: '/org/x/tickets?view=list')
    expect(claim(token)).to be_nil
  end

  it 'stores digests, never the token or the state' do
    token = mint
    row = SessionHandoff.last

    expect(row.token_digest).to eq(described_class.digest(token))
    expect(row.attributes.values.map(&:to_s)).not_to include(token, state)
  end

  it 'refuses another browser, and burns the token doing so' do
    token = mint

    expect(claim(token, claim_state: 'other')).to be_nil
    expect(claim(token, claim_state: '')).to be_nil
    expect(claim(token)).to be_nil
  end

  it 'refuses another host, and burns the token doing so' do
    token = mint

    expect(claim(token, claim_host: 'andere.example.test')).to be_nil
    expect(claim(token)).to be_nil
  end

  it 'refuses an expired token' do
    token = mint
    SessionHandoff.update_all(expires_at: 1.second.ago)

    expect(claim(token)).to be_nil
  end

  it 'refuses an unknown token' do
    mint

    expect(claim('made-up')).to be_nil
    expect(claim('')).to be_nil
  end

  it 'refuses a user who may not sign in any more' do
    token = mint
    allow_any_instance_of(User).to receive(:active_for_authentication?).and_return(false)

    expect(claim(token)).to be_nil
  end

  it 'refuses a state digest that is no digest' do
    expect { mint(state_digest: 'x') }.to raise_error(ArgumentError)
  end

  it 'keeps a path a path' do
    {
      '/org/x' => '/org/x',
      '/a?b=c' => '/a?b=c',
      '//evil.example/x' => '/',
      '/\\evil.example' => '/',
      'https://evil.example/' => '/',
      'evil' => '/',
      "/a\nb" => '/',
      nil => '/',
      "/#{'a' * 2001}" => '/'
    }.each do |given, kept|
      expect(described_class.safe_path(given)).to eq(kept), given.inspect
    end
  end

  it 'clears rows that ran out an hour ago when it mints' do
    mint
    SessionHandoff.update_all(expires_at: 2.hours.ago)

    expect { mint }.not_to change(SessionHandoff, :count)
  end
end
