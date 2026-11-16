# frozen_string_literal: true

require 'rails_helper'

# What: setting, changing and removing an organisation's subdomain, and the hold on a
#   name it leaves (doc/org_subdomains_plan.md, S1, decided 2026-11-16).
# Why: old links keep leading to the organisation for the hold period, and nobody else may
#   take the name meanwhile; an expired hold must not block the name forever.
RSpec.describe Actors::AssignOrganisationSubdomain do
  let(:organisation) { create(:organisation) }
  let(:other) { create(:organisation) }

  def assign(org, name)
    described_class.call(organisation: org, subdomain: name, current_user: nil)
  end

  def names_of(org)
    OrganisationSubdomain.where(organisation: org).order(:subdomain).pluck(:subdomain, :held_until)
  end

  it 'sets a first subdomain' do
    expect(assign(organisation, 'Kunde ')).to be_success
    expect(organisation.reload.current_subdomain.subdomain).to eq('kunde')
  end

  it 'holds the old name for the hold period on a change' do
    assign(organisation, 'alt')

    expect(assign(organisation, 'neu')).to be_success
    old = OrganisationSubdomain.find_by!(subdomain: 'alt')
    expect(old.held_until).to be_within(1.minute).of(OrganisationSubdomain::HOLD_PERIOD.from_now)
    expect(organisation.reload.current_subdomain.subdomain).to eq('neu')
  end

  it 'holds the name when the subdomain is removed' do
    assign(organisation, 'weg')

    expect(assign(organisation, '')).to be_success
    expect(organisation.reload.current_subdomain).to be_nil
    expect(OrganisationSubdomain.held.pluck(:subdomain)).to eq(['weg'])
  end

  it 'does nothing when the name stays the same' do
    assign(organisation, 'gleich')

    expect { assign(organisation, 'Gleich') }.not_to(change { names_of(organisation) })
  end

  it 'lets no other organisation take a held name' do
    assign(organisation, 'alt')
    assign(organisation, 'neu')

    result = assign(other, 'alt')

    expect(result).not_to be_success
    expect(other.reload.current_subdomain).to be_nil
    expect(OrganisationSubdomain.find_by!(subdomain: 'alt').organisation).to eq(organisation)
  end

  it 'lets no other organisation take a current name' do
    assign(organisation, 'besetzt')

    expect(assign(other, 'besetzt')).not_to be_success
  end

  it 'lets the organisation take its held name back' do
    assign(organisation, 'alt')
    assign(organisation, 'neu')

    expect(assign(organisation, 'alt')).to be_success
    expect(organisation.reload.current_subdomain.subdomain).to eq('alt')
    expect(OrganisationSubdomain.find_by!(subdomain: 'neu').held_until).to be_present
  end

  it 'frees a name whose hold ran out' do
    assign(organisation, 'alt')
    assign(organisation, 'neu')
    OrganisationSubdomain.find_by!(subdomain: 'alt').update!(held_until: 1.minute.ago)

    expect(assign(other, 'alt')).to be_success
    expect(OrganisationSubdomain.find_by!(subdomain: 'alt').organisation).to eq(other)
  end

  it 'changes nothing when the new name is refused' do
    assign(organisation, 'bleibt')

    result = assign(organisation, 'www')

    expect(result).not_to be_success
    expect(organisation.reload.current_subdomain.subdomain).to eq('bleibt')
    expect(OrganisationSubdomain.held).to be_empty
  end
end
