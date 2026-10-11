# frozen_string_literal: true

# Self-declared founder data captured at registration when the applicant asks
# for the new-founder discount (doc/billing_preisliste_rabatt_plan.md § 12.3).
#
# Own table rather than columns on accounts for the same reason discounts got
# their own (D3): the fields would be blank for the vast majority of accounts,
# and the record has to survive the decision -- including a rejection, without
# which half the statistics are missing.
class CreateFounderSignups < ActiveRecord::Migration[8.0]
  def change
    create_table :founder_signups, id: :uuid do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid, index: { unique: true }

      # Declared by the applicant. Not verified -- the phone call is the check
      # (§ 12.3.1). revenue_band is a band, never an exact figure: for a sole
      # trader the exact turnover is personal financial data (§ 12.3.2).
      t.string :company_name, null: false
      t.string :company_seat, null: false
      t.date   :founded_on,   null: false
      t.string :revenue_band, null: false
      t.string :phone,        null: false

      # Separate, opt-in consent for sales calls. The call ABOUT this request is
      # covered by the request itself; using the number for advertising is a
      # different purpose (§ 7 UWG). Timestamp mirrors users.terms_accepted_at:
      # the consent must stay provable after the fact.
      t.boolean  :marketing_consent, null: false, default: false
      t.datetime :marketing_consent_at

      # Filled after the call.
      t.string   :status, null: false, default: 'open'
      t.datetime :decided_at
      t.string   :decided_by_email
      t.text     :previous_tools
      t.text     :note

      t.timestamps
    end

    # The operator's working queue: open requests first, newest first.
    add_index :founder_signups, %i[status created_at]
  end
end
