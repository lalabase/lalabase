# frozen_string_literal: true

class AddChannelFrequencyConstraints < ActiveRecord::Migration[8.0]
  def up
    # Add DB-level constraints to enforce channel-specific frequency rules
    # This prevents invalid combinations at the database level
    
    # First clean up existing invalid data (if any)
    execute <<~SQL
      UPDATE notification_preferences 
      SET frequency = 'immediate' 
      WHERE channel = 'in_app' AND frequency NOT IN ('immediate', 'never')
    SQL
    
    execute <<~SQL
      UPDATE notification_preferences 
      SET frequency = 'immediate' 
      WHERE channel = 'webhook' AND frequency NOT IN ('immediate', 'never')  
    SQL
    
    # Then add the constraint with explicit enum casting
    execute <<~SQL
      ALTER TABLE notification_preferences 
      ADD CONSTRAINT check_channel_frequency_combinations 
      CHECK (
        (channel::text = 'in_app' AND frequency::text IN ('immediate', 'never')) OR
        (channel::text = 'email' AND frequency::text IN ('immediate', 'daily', 'weekly', 'never')) OR
        (channel::text = 'webhook' AND frequency::text IN ('immediate', 'never'))
      )
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE notification_preferences 
      DROP CONSTRAINT IF EXISTS check_channel_frequency_combinations
    SQL
  end
end
