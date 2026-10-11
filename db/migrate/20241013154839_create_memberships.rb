class CreateMemberships < ActiveRecord::Migration[7.2]
  def change
    create_table :memberships, id: :uuid do |t|
      t.uuid :user_id, null: false
      t.uuid :organisation_id, null: false
      t.string :role

      t.timestamps
    end
  end
end
