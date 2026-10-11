class CreateBeusers < ActiveRecord::Migration[7.2]
    def change
      create_table :beusers, id: :uuid do |t|
        t.string :firstname
        t.string :lastname
        t.string :email
        t.string :password_digest
        t.string :password_token
        t.string :role, default: 'user'
        t.boolean :active, default: :false
        t.timestamps
      end
    end
  end
