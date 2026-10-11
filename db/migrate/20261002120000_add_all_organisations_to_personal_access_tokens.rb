# frozen_string_literal: true

# A token can reach every organisation its owner is an active member of, now and
# later, instead of a fixed list of organisation links. Read through
# PersonalAccessToken#organisation_scopes, the one place that decides which
# organisations a token reaches. A constant default on a new column is a
# metadata change in PostgreSQL 11+, no table rewrite.
class AddAllOrganisationsToPersonalAccessTokens < ActiveRecord::Migration[8.1]
  def change
    add_column :personal_access_tokens, :all_organisations, :boolean, default: false, null: false
  end
end
