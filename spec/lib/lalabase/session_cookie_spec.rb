# frozen_string_literal: true

require 'rails_helper'

# What: the name and flags of the session cookie (doc/org_subdomains_plan.md, S3).
# Why: under TLS the __Host- prefix keeps a sibling host (stage, demo, stats, an
#   organisation's host) from planting a session cookie the main host would read.
RSpec.describe Lalabase::SessionCookie do
  it 'carries the __Host- prefix and the Secure flag under TLS, one name per environment' do
    expect(described_class.options(rails_env: 'production', secure: true))
      .to eq(key: '__Host-lalabase_production_session', secure: true, same_site: :lax)
    expect(described_class.options(rails_env: 'staging', secure: true)[:key]).to eq('__Host-lalabase_staging_session')
  end

  it 'goes without the prefix without TLS, where a browser would refuse it' do
    expect(described_class.options(rails_env: 'development', secure: false))
      .to eq(key: '_lalabase_development_session', secure: false, same_site: :lax)
  end

  it 'names no domain' do
    expect(described_class.options(rails_env: 'production', secure: true)).not_to have_key(:domain)
  end

  it 'is the session store of this process' do
    expect(Rails.application.config.session_options[:key]).to eq("_lalabase_#{Rails.env}_session")
  end
end
