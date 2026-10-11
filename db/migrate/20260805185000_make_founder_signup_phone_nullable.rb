# frozen_string_literal: true

# The callback number is the ONE field of a founder request that is genuinely
# additional and loses its purpose once the request is decided
# (doc/billing_preisliste_rabatt_plan.md § 12.3.4).
#
# Company name and seat are NOT deleted: the same company sits in accounts.name
# under the contract relationship -- the applicant stays registered even when the
# request is declined, because the request blocks nothing. Deleting the copy
# while the original is two tables away would be theatre.
#
# So the column has to become nullable. Presence at creation stays enforced in
# the model: required when the request is made, removable afterwards.
class MakeFounderSignupPhoneNullable < ActiveRecord::Migration[8.0]
  def change
    change_column_null :founder_signups, :phone, true
  end
end
