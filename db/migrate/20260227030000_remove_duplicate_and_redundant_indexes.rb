class RemoveDuplicateAndRedundantIndexes < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    # 1) imported_objects: exact duplicate from t.references + explicit add_index
    remove_index_concurrently_if_exists :imported_objects,
      name: :index_imported_objects_on_importable_type_and_importable_id

    # 2) fragments: exact duplicate from t.references + explicit add_index
    remove_index_concurrently_if_exists :fragments,
      name: :index_fragments_on_fragmentable_type_and_fragmentable_id

    # 3) email_logs: full index redundant — partial idx_email_logs_provider_msg is sufficient
    remove_index_concurrently_if_exists :email_logs,
      name: :index_email_logs_on_provider_message_id

    # 4) email_logs: notification_id single-column covered by (notification_id, status) composite
    remove_index_concurrently_if_exists :email_logs,
      name: :index_email_logs_on_notification_id

    # 5) email_logs: organisation_id single-column covered by multiple composites
    #    (organisation_id, status), (organisation_id, sent_at), (organisation_id, status, created_at)
    remove_index_concurrently_if_exists :email_logs,
      name: :index_email_logs_on_organisation_id
  end

  def down
    add_index :imported_objects, [:importable_type, :importable_id],
      name: :index_imported_objects_on_importable_type_and_importable_id,
      algorithm: :concurrently

    add_index :fragments, [:fragmentable_type, :fragmentable_id],
      name: :index_fragments_on_fragmentable_type_and_fragmentable_id,
      algorithm: :concurrently

    add_index :email_logs, :provider_message_id,
      name: :index_email_logs_on_provider_message_id,
      algorithm: :concurrently

    add_index :email_logs, :notification_id,
      name: :index_email_logs_on_notification_id,
      algorithm: :concurrently

    add_index :email_logs, :organisation_id,
      name: :index_email_logs_on_organisation_id,
      algorithm: :concurrently
  end

  private

  def remove_index_concurrently_if_exists(table, name:)
    return unless connection.index_name_exists?(table, name)

    remove_index table, name: name, algorithm: :concurrently
  end
end
