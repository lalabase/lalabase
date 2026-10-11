# frozen_string_literal: true

# The column already carries a DB default and the model declares the enum with
# `validate: true`, so nothing in the application can write NULL. The SCHEMA still
# allowed it, and that gap is not academic: the admin billing block builds its
# label key from the stored value, so a single NULL -- via update_columns, a console
# session or a future backfill -- renders "translation missing" onto the page an
# operator uses to decide whether an invoice may go out.
#
# Closing it in the schema rather than defending against it in the view: a view
# guard would be a comment about a state the database still permits, and the next
# reader of the column would have no way to know it is forbidden.
#
# No backfill step needed, measured before writing this: production holds 9 accounts,
# all of them 'unchecked', none NULL. The UPDATE below is the belt-and-braces for
# dev and test databases, and it is a no-op wherever it is already true.
class MakeVatIdStatusNotNull < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL.squish
      UPDATE accounts SET vat_id_status = 'unchecked' WHERE vat_id_status IS NULL
    SQL
    change_column_null :accounts, :vat_id_status, false
  end

  def down
    change_column_null :accounts, :vat_id_status, true
  end
end
