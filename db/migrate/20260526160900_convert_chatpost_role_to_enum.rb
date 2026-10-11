# frozen_string_literal: true

class ConvertChatpostRoleToEnum < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL.squish
      CREATE TYPE chatpost_role AS ENUM ('system', 'user', 'assistant')
    SQL

    execute <<~SQL.squish
      UPDATE chatposts
         SET role = 'user'
       WHERE role IS NULL OR role NOT IN ('system', 'user', 'assistant')
    SQL

    execute <<~SQL.squish
      ALTER TABLE chatposts
        ALTER COLUMN role TYPE chatpost_role USING role::chatpost_role,
        ALTER COLUMN role SET NOT NULL,
        ALTER COLUMN role SET DEFAULT 'user'
    SQL
  end

  def down
    execute <<~SQL.squish
      ALTER TABLE chatposts
        ALTER COLUMN role DROP DEFAULT,
        ALTER COLUMN role TYPE varchar USING role::text,
        ALTER COLUMN role DROP NOT NULL
    SQL

    execute 'DROP TYPE IF EXISTS chatpost_role'
  end
end
