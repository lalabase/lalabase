# frozen_string_literal: true

# The package name is the catalogue card title (plan §7b.1) and validated
# unique at the model — this index makes the database the last instance
# against the concurrent-create race and lets the model validation drop its
# Rails/UniqueValidationWithoutIndex waiver.
class AddUniqueIndexToAiPackagesName < ActiveRecord::Migration[8.0]
  def change
    add_index :ai_packages, :name, unique: true
  end
end
