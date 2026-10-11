class AddMissingSolidQueueIndexes < ActiveRecord::Migration[8.0]
  def change
    # Add missing unique index on name and supervisor_id for solid_queue_processes
    unless index_exists?(:solid_queue_processes, [:name, :supervisor_id], unique: true)
      add_index :solid_queue_processes, [:name, :supervisor_id], unique: true, name: "index_solid_queue_processes_on_name_and_supervisor_id"
    end
    
    # Ensure this index exists but wasn't added by our previous migrations
    unless index_exists?(:solid_queue_processes, :name)
      add_index :solid_queue_processes, :name
    end
  end
end