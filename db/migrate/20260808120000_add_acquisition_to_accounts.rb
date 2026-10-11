# frozen_string_literal: true

# Where a customer came from, on the ACCOUNT rather than the organisation
# (doc/akquise_herkunft.md): the account is the customer, a second organisation
# inside the same account is not a second acquisition, and FounderSignup already
# hangs off the account -- so one column answers "where did this founder request
# come from" without a second copy of the same data.
#
# No index on purpose. Every query over this column is a full grouping over a
# table with a few hundred rows at most, which PostgreSQL does with a seq scan
# either way; a GIN index would cost write time and disk to speed up nothing.
# Revisit if the accounts table ever reaches five figures.
class AddAcquisitionToAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :accounts, :acquisition, :jsonb
  end
end
