# frozen_string_literal: true

require 'rails_helper'

# What: the rule of a name an organisation is shown under (doc/org_subdomains_plan.md, S1).
# Why: the name becomes a host. A reserved name would pass for a part of the service, a
#   second row with the same name would make the host ambiguous.
RSpec.describe OrganisationSubdomain do
  let(:organisation) { create(:organisation) }

  def build_name(name, **attrs)
    described_class.new(organisation: organisation, subdomain: name, **attrs)
  end

  it 'takes one DNS label of 3 to 63 characters' do
    expect(build_name('abc')).to be_valid
    expect(build_name('a' * 63)).to be_valid
    expect(build_name('muster-gmbh')).to be_valid
    expect(build_name('ab')).not_to be_valid
    expect(build_name('a' * 64)).not_to be_valid
  end

  it 'refuses what is no DNS label' do
    ['-abc', 'abc-', 'a_bc', 'a.bc', 'ab c', 'müller'].each do |name|
      expect(build_name(name)).not_to be_valid, name
    end
  end

  # A browser shows an encoded label as other letters: xn--mnchen-3ya reads münchen.
  it 'refuses two hyphens at the third and fourth place' do
    ['xn--mnchen-3ya', 'ab--cd'].each do |name|
      record = build_name(name)
      expect(record).not_to be_valid, name
      expect(record.errors.details[:subdomain]).to include(a_hash_including(error: :encoded))
    end
    expect(build_name('a--bc')).to be_valid
    expect(build_name('abc--d')).to be_valid
  end

  it 'stores the name in lower case without surrounding space' do
    expect(build_name('  Muster-GmbH ').subdomain).to eq('muster-gmbh')
  end

  it 'refuses every reserved name' do
    described_class::RESERVED.each do |name|
      record = build_name(name)
      expect(record).not_to be_valid, name
      expect(record.errors.details[:subdomain]).to include(a_hash_including(error: :exclusion))
    end
  end

  it 'reserves the names already used by the service' do
    expect(described_class::RESERVED).to include('www', 'stage', 'demo', 'stats', 'admin', 'api', 'login')
    expect(described_class::RESERVED).to include('autodiscover', 'autoconfig', 'mta-sts', 'wpad')
    expect(described_class::RESERVED).to include('account', 'accounts', 'secure', 'signin', 'sso')
  end

  it 'refuses a name another row has, current or held' do
    described_class.create!(organisation: create(:organisation), subdomain: 'taken',
                            held_until: 1.day.from_now)

    expect(build_name('taken')).not_to be_valid
  end

  it 'holds the uniqueness in the database as well' do
    described_class.create!(organisation: create(:organisation), subdomain: 'twice')

    expect { build_name('twice').save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'allows one current name per organisation in the database' do
    described_class.create!(organisation: organisation, subdomain: 'first')

    expect { build_name('second').save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'tells current, held and expired rows apart' do
    current = described_class.create!(organisation: organisation, subdomain: 'now')
    held = described_class.create!(organisation: organisation, subdomain: 'before', held_until: 1.day.from_now)
    expired = described_class.create!(organisation: organisation, subdomain: 'long-ago', held_until: 1.day.ago)

    expect(described_class.current).to contain_exactly(current)
    expect(described_class.held).to contain_exactly(held)
    expect(described_class.expired).to contain_exactly(expired)
  end

  # By the foreign key, so a deletion through the admin twin (which declares no
  # association for these rows) takes them along as well.
  it 'goes with its organisation in the database' do
    described_class.create!(organisation: organisation, subdomain: 'gone')

    expect { Organisation.where(id: organisation.id).delete_all }.to change(described_class, :count).by(-1)
  end
end
