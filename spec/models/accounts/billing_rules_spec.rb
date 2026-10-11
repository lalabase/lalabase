# frozen_string_literal: true

require 'rails_helper'

# What: Accounts::BillingRules and Accounts::BillingAddress (B1).
# Type: Model spec.
# Why:  The country lists are a legal statement (E11) and a library contract at
#       the same time. Both fail silently: a country wrongly inside the list
#       demands a VAT ID nobody can supply, one wrongly outside lets an EU sale
#       through untaxed, and a prefix valvat no longer covers turns the format
#       check into a no-op. None of that shows up in the UI.
RSpec.describe Accounts::BillingRules do
  describe 'EU_VAT_COUNTRIES' do
    it 'lists the 27 member states' do
      expect(described_class::EU_VAT_COUNTRIES.size).to eq(27)
    end

    # The reason this list is written out instead of derived: the countries gem
    # answers in_eu? for 34 codes, because it counts the French overseas
    # departments, Saint-Martin and Åland. Those are EU territory but OUTSIDE
    # the EU VAT area, so deriving the list would demand a VAT ID from a
    # customer in Guadeloupe who cannot have one.
    it 'excludes EU territories that are outside the VAT area' do
      expect(described_class::EU_VAT_COUNTRIES).not_to include('GF', 'GP', 'MQ', 'RE', 'YT', 'MF', 'AX')
      expect(ISO3166::Country.all.select(&:in_eu?).map(&:alpha2)).to include('GF', 'AX')
    end

    it 'contains only codes the ISO list knows' do
      expect(described_class::EU_VAT_COUNTRIES - ISO3166::Country.codes).to be_empty
    end
  end

  # The comment on PERMITTED_FIELDS names the risk precisely: a customer must
  # not be able to set themselves to "VAT ID verified". Nothing pinned that.
  # Once B2 hangs its Strong Parameters on this list, a later addition to
  # OPTIONAL_FIELDS would open the hole without a sound.
  describe 'PERMITTED_FIELDS' do
    # Derived from the table, not typed out: a column added later is covered
    # without anyone remembering this spec.
    let(:system_set_columns) do
      Account.column_names.grep(/\A(vat_id_status|vat_id_checked_|business_confirmed_|business_confirmation_)/)
    end

    it 'covers every column the system sets itself' do
      expect(system_set_columns).to match_array(
        %w[vat_id_status vat_id_checked_at vat_id_checked_name
           business_confirmed_at business_confirmed_by_id business_confirmation_version]
      )
    end

    it 'permits none of them' do
      expect(described_class::PERMITTED_FIELDS.map(&:to_s) & system_set_columns).to be_empty
    end

    it 'permits exactly what the two lists promise, and only real columns' do
      expect(described_class::PERMITTED_FIELDS).to match_array(
        described_class::REQUIRED_FIELDS + described_class::OPTIONAL_FIELDS
      )
      expect(described_class::PERMITTED_FIELDS.map(&:to_s) - Account.column_names).to be_empty
    end
  end

  describe 'VAT_ID_REQUIRED_COUNTRIES' do
    it 'covers the EU except Germany (E11)' do
      expect(described_class::VAT_ID_REQUIRED_COUNTRIES).not_to include('DE')
      expect(described_class::VAT_ID_REQUIRED_COUNTRIES.size).to eq(26)
    end
  end

  # Agreement with the library, not mere presence: if valvat drops or adds a
  # pattern, this is the only place that notices.
  describe 'VAT_FORMAT_CHECKED_PREFIXES' do
    # Compared against the library's own pattern table rather than against
    # sample numbers: each country has its own length and letter rules, so
    # synthetic IDs would fail for reasons that say nothing about coverage.
    # valvat keys its table by ISO code (GR), the prefix override is what turns
    # that into the EL the customer actually types.
    it 'matches the country set valvat carries patterns for' do
      ours = described_class::VAT_FORMAT_CHECKED_PREFIXES
             .map { |prefix| described_class::VAT_PREFIX_TO_PATTERN_KEY.fetch(prefix, prefix) }

      expect(ours.uniq.sort).to eq(Valvat::Syntax::VAT_PATTERNS.keys.map(&:to_s).sort)
    end

    it 'uses EL for Greece, not the country code GR' do
      expect(described_class::VAT_FORMAT_CHECKED_PREFIXES).to include('EL')
      expect(described_class::VAT_FORMAT_CHECKED_PREFIXES).not_to include('GR')
    end

    # valvat's GB pattern is /\A(GB|XI)…/, so it CAN check a Northern Irish
    # number. Without XI in the list the check would skip it, which is a hole in
    # exactly the check that is supposed to be context-free.
    it 'covers Northern Ireland, which shares the GB pattern' do
      expect(described_class).to be_vat_format_checkable('XI123456789')
      expect(Valvat.new('XI123456789')).to be_valid
    end

    it 'leaves countries valvat cannot check alone' do
      expect(described_class).not_to be_vat_format_checkable('CHE-116.281.710')
      expect(described_class).to be_vat_format_checkable('DE811907980')
    end
  end
end

RSpec.describe Accounts::BillingAddress do
  let(:account) do
    build(:account, billing_name: 'Muster GmbH', billing_addressee: 'z. Hd. Buchhaltung',
                    billing_street: 'Musterweg 1', billing_postal_code: '10115',
                    billing_city: 'Berlin', billing_country: 'DE')
  end

  it 'renders postal order and drops the blank lines' do
    expect(account.billing_address.lines).to eq(
      ['Muster GmbH', 'z. Hd. Buchhaltung', 'Musterweg 1', '10115 Berlin', 'Deutschland']
    )
  end

  it 'resolves the country code to a localised name' do
    expect(account.billing_address.country_name).to eq('Deutschland')
  end

  it 'falls back to the raw code for a country it cannot resolve' do
    account.billing_country = 'ZZ'

    expect(account.billing_address.country_name).to eq('ZZ')
  end

  # This hash is what an invoice freezes. It uses the column names so a stored
  # copy stays readable next to the table it came from.
  it 'exposes a snapshot keyed by column name' do
    expect(account.billing_address.to_h).to include(
      billing_name: 'Muster GmbH', billing_country: 'DE', billing_region: nil
    )
  end

  it 'knows when there is nothing to render' do
    expect(build(:account).billing_address).not_to be_present
    expect(account.billing_address).to be_present
  end
end

# N3: AccountPolicy#claim? and #claim! both test `owner`, which SoftDeletable
# scopes away. #orphan? used to test owner_id and therefore disagreed with them
# for a soft-deleted owner: the customer saw the claim banner while the
# operator's badge still read "has an owner". Users are never hard-deleted in
# this app, so that is the normal case rather than an edge one.
RSpec.describe Account, '#orphan?' do
  let(:user) { create(:user) }
  let(:account) { create(:account, owner: user) }

  it 'is false while the owner exists' do
    expect(account).not_to be_orphan
  end

  it 'is true once the owner is soft-deleted, matching claim?' do
    user.update_columns(deleted_at: Time.current)

    expect(account.reload).to be_orphan
    expect(account.owner_id).to be_present
  end
end
