class CreateTicketAssignments < ActiveRecord::Migration[7.2]
  def change
    create_table :ticket_assignments do |t|
      t.uuid :ticket_id, null: false
      t.uuid :user_id, null: false

      t.timestamps
    end
  end
end
