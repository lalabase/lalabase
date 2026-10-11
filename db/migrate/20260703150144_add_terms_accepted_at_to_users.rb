class AddTermsAcceptedAtToUsers < ActiveRecord::Migration[8.0]
  # Records when a user accepted the terms of service (Art. 13 GDPR transparency
  # at the point of collection). Nullable and without backfill: existing accounts
  # predate the consent checkbox, so a missing value means "accepted before this
  # was tracked", not "never accepted".
  def change
    add_column :users, :terms_accepted_at, :datetime
  end
end
