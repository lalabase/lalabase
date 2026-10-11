class CreateInvitations < ActiveRecord::Migration[7.2]
  def change
    create_table :invitations, id: :uuid do |t|
      t.string :email
      t.string :token
      t.uuid :organisation_id, null: false
      t.uuid :inviter_id, null: false
      t.datetime :sent_at
      t.datetime :accepted_at

      t.timestamps
    end
  end
end
