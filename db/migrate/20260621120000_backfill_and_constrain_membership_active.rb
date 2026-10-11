# frozen_string_literal: true

# Backfill legacy memberships and lock down the `active` flag.
#
# add_active_to_memberships (20241016134647) added the column nullable, with no
# default and no backfill. Rows created before the app set active: true
# consistently are stuck at NULL, which the `active` scope (where(active: true))
# silently excludes. On entry that yields "no active membership" ->
# Organisations::BaseController redirects the user out, producing an inescapable
# redirect loop. Backfill those rows to true and make the column NOT NULL with a
# safe default so the NULL state can never reappear.
#
# Intentional deactivations (active: false) are left untouched; only NULL rows are
# backfilled, via the 4th argument of change_column_null.
class BackfillAndConstrainMembershipActive < ActiveRecord::Migration[8.0]
  def up
    change_column_null :memberships, :active, false, true
    change_column_default :memberships, :active, from: nil, to: true
  end

  def down
    change_column_default :memberships, :active, from: true, to: nil
    change_column_null :memberships, :active, true
  end
end
