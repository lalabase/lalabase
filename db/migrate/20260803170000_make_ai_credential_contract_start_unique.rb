# frozen_string_literal: true

# The no-overlap rule of EffectiveDating is app-level by design (see the
# concern's header). For price lists that is enough -- a duplicate there is a
# cosmetic mistake. Here the row is an ASSURANCE the operator gives their own
# customers, and the model header promises that "what did we state on date X"
# has exactly one answer.
#
# The realistic way to break that promise is a double-submitted form: both
# requests read the same running version, both clip it, both insert. Neither
# validation sees the other's uncommitted row. The unique index is the last
# instance that does.
#
# It closes the same-day case, not every conceivable overlap -- the complete
# variant would be a PostgreSQL EXCLUDE constraint over daterange + btree_gist,
# which the concern already names as the retrofit path.
class MakeAiCredentialContractStartUnique < ActiveRecord::Migration[8.0]
  def up
    remove_index :ai_credential_contracts, column: %i[ai_credential_id starts_on]
    add_index :ai_credential_contracts, %i[ai_credential_id starts_on],
              unique: true, name: 'idx_credential_contracts_unique_start'
  end

  def down
    remove_index :ai_credential_contracts, name: 'idx_credential_contracts_unique_start'
    add_index :ai_credential_contracts, %i[ai_credential_id starts_on]
  end
end
