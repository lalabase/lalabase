# frozen_string_literal: true

require 'rails_helper'

# What: which host shows which organisation (doc/org_subdomains_plan.md, S2).
# Why: the gate and the redirect read this one answer; a held name must still lead to its
#   organisation, an expired or unknown one to nobody.
RSpec.describe Organisations::Hosts do
  let(:organisation) { create(:organisation) }

  def place(host)
    described_class.call(host: host)
  end

  context 'with organisation subdomains switched off' do
    before { allow(described_class).to receive(:parent_domain).and_return(nil) }

    it 'answers off for every host and names no host for an organisation' do
      OrganisationSubdomain.create!(organisation: organisation, subdomain: 'kunde')

      expect(place('kunde.example.test').kind).to eq(:off)
      expect(described_class.host_for(organisation)).to be_nil
    end
  end

  context 'with a tenant domain' do
    before { allow(described_class).to receive(:parent_domain).and_return('example.test') }

    it 'tells the kinds of host apart' do
      OrganisationSubdomain.create!(organisation: organisation, subdomain: 'kunde')
      OrganisationSubdomain.create!(organisation: organisation, subdomain: 'alt', held_until: 1.day.from_now)
      OrganisationSubdomain.create!(organisation: organisation, subdomain: 'uralt', held_until: 1.day.ago)

      expect(place('example.test').kind).to eq(:main)
      expect(place('other.test').kind).to eq(:elsewhere)
      expect(place('kunde.example.test')).to have_attributes(kind: :current, organisation: organisation)
      expect(place('KUNDE.example.test').kind).to eq(:current)
      expect(place('alt.example.test')).to have_attributes(kind: :held, organisation: organisation)
      expect(place('uralt.example.test').kind).to eq(:unknown)
      expect(place('niemand.example.test').kind).to eq(:unknown)
      expect(place('a.kunde.example.test').kind).to eq(:unknown)
    end

    it 'names the host an organisation belongs on' do
      expect(described_class.host_for(organisation)).to eq('example.test')

      OrganisationSubdomain.create!(organisation: organisation, subdomain: 'kunde')

      expect(described_class.host_for(organisation.reload)).to eq('kunde.example.test')
    end
  end
end
