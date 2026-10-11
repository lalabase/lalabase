# frozen_string_literal: true

require 'rails_helper'

# What: the billing master data on Account (B1 of doc/billing_stammdaten_plan.md).
# Type: Model spec.
# Why:  Two properties carry this slice and both fail SILENTLY when broken:
#         1. The :billing context must not leak into the default context. Every
#            existing account has no billing data (1:1 backfill, ensure_account,
#            factories); a leak would make them all invalid at once, and the
#            damage would show up far away from here.
#         2. All-or-nothing. The owner may clear the data completely but must not
#            leave it half filled. An early return inside a custom validator
#            would NOT stop the declarative ones, so clearing would be
#            impossible, and nobody would notice until a customer tried.
RSpec.describe Account, 'billing details' do
  subject(:account) { build(:account) }

  let(:complete_attributes) do
    { billing_name: 'Muster GmbH', billing_street: 'Musterweg 1',
      billing_postal_code: '10115', billing_city: 'Berlin',
      billing_country: 'DE', billing_email: 'rechnung@muster.de' }
  end

  # The plan's test list (§11) asks for two things that cannot both hold: an
  # account without billing data should be "valid? but NOT valid?(:billing)",
  # while E3 requires that completely empty data passes so an owner can clear
  # it. Empty is empty, so the all-or-nothing rule wins and the :billing context
  # accepts it.
  #
  # The requirement behind the first line is real, it just belongs to a
  # different gate: the FORM saves with the :billing context and must allow
  # clearing, the CHECKOUT asks #billing_complete? and must not accept nothing.
  # Conflating them would either make clearing impossible or let a customer
  # check out with no invoice address.
  describe 'the two gates' do
    it 'leaves an account without any billing data valid in both contexts' do
      expect(account).to be_valid
      expect(account).to be_valid(:billing)
      expect(account.save).to be(true)
    end

    it 'still reports that account as incomplete' do
      expect(account).not_to be_billing_complete
    end
  end

  describe 'all-or-nothing (E3)' do
    it 'accepts completely empty billing data even in the :billing context' do
      account.assign_attributes(complete_attributes.transform_values { '' })

      expect(account).to be_valid(:billing)
    end

    it 'rejects half-filled billing data' do
      account.assign_attributes(complete_attributes.merge(billing_city: ''))

      expect(account).not_to be_valid(:billing)
      expect(account.errors.attribute_names).to contain_exactly(:billing_city)
    end

    it 'accepts complete billing data' do
      account.assign_attributes(complete_attributes)

      expect(account).to be_valid(:billing)
    end
  end

  describe 'billing_region' do
    it 'is required for a country that needs a subdivision' do
      account.assign_attributes(complete_attributes.merge(billing_country: 'US',
                                                          billing_postal_code: '10001'))

      expect(account).not_to be_valid(:billing)
      expect(account.errors.attribute_names).to include(:billing_region)
    end

    it 'is not required for Germany' do
      account.assign_attributes(complete_attributes)

      expect(account).to be_valid(:billing)
    end

    # A country that is in neither constant must not accidentally inherit a rule.
    it 'is not required for a country outside the list' do
      account.assign_attributes(complete_attributes.merge(billing_country: 'CH'))

      expect(account).to be_valid(:billing)
    end
  end

  describe 'vat_id requirement (E11)' do
    it 'is required for an EU country outside Germany' do
      account.assign_attributes(complete_attributes.merge(billing_country: 'FR'))

      expect(account).not_to be_valid(:billing)
      expect(account.errors.attribute_names).to include(:vat_id)
    end

    it 'is not required for Germany' do
      account.assign_attributes(complete_attributes)

      expect(account).to be_valid(:billing)
    end

    it 'is not required outside the EU' do
      account.assign_attributes(complete_attributes.merge(billing_country: 'US',
                                                          billing_region: 'NY'))

      expect(account).to be_valid(:billing)
    end
  end

  describe 'vat_id format (E4)' do
    it 'accepts a valid id' do
      account.vat_id = 'DE811907980'

      expect(account).to be_valid
    end

    # valvat#valid? would pass this: it only checks syntax. The check digit is
    # what separates a typo from a real number.
    it 'rejects an id whose check digit is wrong' do
      account.vat_id = 'DE123456789'

      expect(account).not_to be_valid
      expect(account.errors.attribute_names).to include(:vat_id)
    end

    # Context-free: a broken id must not reach the database through any path,
    # not just through the billing form.
    it 'rejects it in the default context too' do
      account.vat_id = 'DE123456789'

      expect(account.save).to be(false)
    end

    # The message is reachable from B1 onwards, so it needs its keys now. A
    # missing one does not raise: it renders the "translation missing" block
    # into the form, in production, looking like a broken field.
    it 'renders a real message in both locales' do
      account.vat_id = 'DE123456789'
      account.valid?

      # `include`, not `.last`: pinning by position would silently check a
      # different message as soon as another validation is added.
      expect(account.errors.full_messages).to include('USt-IdNr. hat ein ungültiges Format')

      I18n.with_locale(:en) do
        english = build(:account, vat_id: 'DE123456789')
        english.valid?
        expect(english.errors.full_messages).to include('VAT ID has an invalid format')
      end
    end

    # The second new validator of this slice. Without its own key the German
    # customer reads the English fallback in a German form (production has
    # i18n.fallbacks on, and rails-i18n is not bundled).
    it 'renders a real message for an unknown country in both locales' do
      account.billing_country = 'XX'
      account.valid?

      expect(account.errors.full_messages).to include('Land ist kein gültiger Wert')

      I18n.with_locale(:en) do
        english = build(:account, billing_country: 'XX')
        english.valid?
        expect(english.errors.full_messages).to include('Country is not a valid value')
      end
    end

    # valvat covers the EU and GB. For CH it would reject a VALID number, so the
    # check must not run there. Without this the whole country is locked out.
    it 'does not reject a Swiss number it cannot check' do
      account.assign_attributes(complete_attributes.merge(billing_country: 'CH',
                                                          vat_id: 'CHE-116.281.710'))

      expect(account).to be_valid(:billing)
    end

    # Greece is country code GR but its VAT ids start with EL. Validating the id
    # against the country code would lock out every Greek customer.
    it 'accepts a Greek id although it does not start with the country code' do
      account.assign_attributes(complete_attributes.merge(billing_country: 'GR',
                                                          vat_id: 'EL090165560'))

      expect(account).to be_valid(:billing)
    end
  end

  describe 'normalisation' do
    it 'strips spaces and dots from the vat_id and upcases it' do
      account.vat_id = 'de 811.907.980'
      account.valid?

      expect(account.vat_id).to eq('DE811907980')
    end

    it 'upcases the country code' do
      account.billing_country = 'de'
      account.valid?

      expect(account.billing_country).to eq('DE')
    end

    it 'rejects a country code that does not exist' do
      account.billing_country = 'XX'

      expect(account).not_to be_valid
      expect(account.errors.attribute_names).to include(:billing_country)
    end
  end

  # Without this the support screen would show "verified" for a number nobody
  # ever checked, which is worse than showing nothing.
  describe 'vat_id verification reset (E4)' do
    it 'resets status and evidence when the id changes' do
      account.save!
      account.update_columns(vat_id: 'DE811907980', vat_id_status: 'valid',
                             vat_id_checked_at: Time.current,
                             vat_id_checked_name: 'Muster GmbH')

      account.reload.update!(vat_id: 'ATU13585627')

      expect(account).to have_attributes(vat_id_status: 'unchecked',
                                         vat_id_checked_at: nil,
                                         vat_id_checked_name: nil)
    end

    it 'leaves the verification alone when something else changes' do
      account.save!
      account.update_columns(vat_id: 'DE811907980', vat_id_status: 'valid')

      account.reload.update!(billing_city: 'Hamburg')

      expect(account.vat_id_status).to eq('valid')
    end
  end

  describe '#billing_complete?' do
    it 'is false while a single required field is missing' do
      account.assign_attributes(complete_attributes.merge(billing_city: nil))

      expect(account).not_to be_billing_complete
    end

    it 'is true once every required field is filled' do
      account.assign_attributes(complete_attributes)

      expect(account).to be_billing_complete
    end

    it 'is false for an EU account outside Germany without a vat_id' do
      account.assign_attributes(complete_attributes.merge(billing_country: 'FR'))

      expect(account).not_to be_billing_complete
    end

    it 'is false when a required subdivision is missing' do
      account.assign_attributes(complete_attributes.merge(billing_country: 'US'))

      expect(account).not_to be_billing_complete
    end
  end

  # The third predicate (B4). It exists because the two above answer a different question,
  # and both display surfaces used to approximate it with "address or e-mail present".
  describe '#billing_details_present?' do
    it 'is false for an account nobody has touched' do
      expect(account).not_to be_billing_details_present
    end

    it 'is true once the required fields are filled' do
      account.assign_attributes(complete_attributes)

      expect(account).to be_billing_details_present
    end

    # The whole reason for the wider field set. billing_reference is an OPTIONAL_FIELD, so
    # it neither makes the account complete nor triggers the :billing validation -- a
    # customer can save it on its own, and the pages have to admit it exists.
    it 'is true for an optional field on its own' do
      account.billing_reference = 'PO-4711'

      expect(account).to be_billing_details_present
      expect(account).not_to be_billing_complete
      expect(account).to be_billing_fields_all_blank
    end

    it 'is true for a cc address on its own' do
      account.billing_email_cc = 'kopie@muster.de'

      expect(account).to be_billing_details_present
    end
  end

  # The schema now forbids what the model already forbade. Without the NOT NULL, the admin
  # page builds `t("...vat_id_status.")` from a NULL and renders "translation missing" onto
  # the screen an operator decides invoices on. update_columns is the only way in, which is
  # precisely why the database has to be the one refusing it.
  describe 'vat_id_status NOT NULL' do
    it 'refuses a NULL written past the model' do
      account.save!

      expect { account.update_columns(vat_id_status: nil) }
        .to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  # The enum value `valid` would generate Account#valid? and shadow
  # ActiveRecord's own, so the prefix is load-bearing rather than cosmetic.
  describe 'vat_id_status enum' do
    it 'defaults to unchecked' do
      expect(account.vat_id_status).to eq('unchecked')
    end

    it 'exposes prefixed predicates and leaves valid? to ActiveRecord' do
      account.vat_id_status = 'valid'

      expect(account).to be_vat_id_status_valid
      expect(account.method(:valid?).owner).not_to eq(described_class)
    end
  end
end
