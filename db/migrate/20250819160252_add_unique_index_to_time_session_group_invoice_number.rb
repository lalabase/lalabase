class AddUniqueIndexToTimeSessionGroupInvoiceNumber < ActiveRecord::Migration[8.0]
  def change
    add_index :time_session_groups, [:organisation_id, :invoice_number], 
              unique: true, 
              where: "invoice_number IS NOT NULL",
              name: "index_time_session_groups_on_org_and_invoice_number_unique"
  end
end
