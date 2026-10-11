class AddAttributeGroupToProjects < ActiveRecord::Migration[8.0]
  def change
    add_reference :projects, :attribute_group, foreign_key: true, type: :uuid
    
    # Add index for performance
    add_index :projects, [:organisation_id, :attribute_group_id]
  end
end