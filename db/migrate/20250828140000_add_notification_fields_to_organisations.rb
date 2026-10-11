# frozen_string_literal: true

class AddNotificationFieldsToOrganisations < ActiveRecord::Migration[8.0]
  def change
    add_column :organisations, :email_subject_prefix, :string
    add_column :organisations, :notification_sender_email, :string
    
    # Add index for better query performance
    add_index :organisations, :notification_sender_email
  end
end