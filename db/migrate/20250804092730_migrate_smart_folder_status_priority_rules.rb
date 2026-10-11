class MigrateSmartFolderStatusPriorityRules < ActiveRecord::Migration[8.0]
  def up
    # Migrate existing SmartFolder rules from status/priority to Custom Attributes
    # This assumes that status and priority already exist as Custom Attributes

    say_with_time "Migrating SmartFolder rules from status/priority to custom attributes" do
      updated_count = 0
      
      # Find all SmartFolder rules with field='status' or field='priority'
      SmartFolderRule.where(field: ['status', 'priority']).find_each do |rule|
        old_field = rule.field

        # Convert to custom_status or custom_priority
        new_field = "custom_#{old_field}"

        # Update the rule
        rule.update_columns(
          field: new_field,
          updated_at: Time.current
        )
        
        updated_count += 1

        # Log the change
        say "Updated rule #{rule.id}: #{old_field} -> #{new_field}", true
      end
      
      say "Updated #{updated_count} SmartFolder rules", true
    end
  end
  
  def down
    # Rollback: Convert custom_status/custom_priority back to status/priority
    say_with_time "Rolling back SmartFolder rules from custom attributes to status/priority" do
      updated_count = 0
      
      SmartFolderRule.where(field: ['custom_status', 'custom_priority']).find_each do |rule|
        old_field = rule.field
        
        # Remove the custom_ prefix
        new_field = old_field.gsub('custom_', '')
        
        rule.update_columns(
          field: new_field,
          updated_at: Time.current
        )
        
        updated_count += 1
        
        say "Rolled back rule #{rule.id}: #{old_field} -> #{new_field}", true
      end
      
      say "Rolled back #{updated_count} SmartFolder rules", true
    end
  end
end
