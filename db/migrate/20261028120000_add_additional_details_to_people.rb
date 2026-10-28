# frozen_string_literal: true

# Up to ten labelled details of a person (fax, mobile, website, birthday), as
# one JSONB array next to the fixed fields. The check constraint is the second
# line behind the model validation (PersonDetail): a console write or a later
# API cannot store an object or an eleventh entry.
class AddAdditionalDetailsToPeople < ActiveRecord::Migration[8.1]
  def change
    add_column :people, :additional_details, :jsonb, null: false, default: []
    add_check_constraint :people,
                         "jsonb_typeof(additional_details) = 'array' AND jsonb_array_length(additional_details) <= 10",
                         name: 'people_additional_details_shape'
  end
end
