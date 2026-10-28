# frozen_string_literal: true

# The salutation of a person in the people directory ("Herr", "Frau Dr."), free
# text. Often only "Frau Müller" is known, without a first name; the salutation
# says how to address her. Empty means none given. No default, so no rewrite.
class AddSalutationToPeople < ActiveRecord::Migration[8.1]
  def change
    add_column :people, :salutation, :string
  end
end
