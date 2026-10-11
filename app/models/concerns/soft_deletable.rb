# frozen_string_literal: true

module SoftDeletable
  extend ActiveSupport::Concern

  included do
    # Only apply soft delete logic if deleted_at column exists.
    # Robust against environments where DB is unavailable during boot.
    has_deleted_at_column = begin
      column_names.include?('deleted_at')
    rescue StandardError
      false
    end

    if has_deleted_at_column
      # Default scope excludes soft-deleted records
      default_scope { where(deleted_at: nil) }

      # Scopes
      scope :deleted, -> { unscoped.where.not(deleted_at: nil) }
      scope :with_deleted, -> { unscoped }
      scope :only_deleted, -> { unscoped.where.not(deleted_at: nil) }
    else
      # Fallback scopes when deleted_at column doesn't exist
      scope :deleted, -> { none }
      scope :with_deleted, -> { all }
      scope :only_deleted, -> { none }
    end
  end

  # Soft delete the record
  def soft_delete!
    if self.class.column_names.include?('deleted_at')
      touch(:deleted_at)
    else
      Rails.logger.warn "soft_delete! called on #{self.class.name} but deleted_at column doesn't exist"
      destroy! # Fallback to hard delete
    end
  end

  # Restore a soft-deleted record
  def restore!
    if self.class.column_names.include?('deleted_at')
      update!(deleted_at: nil)
    else
      Rails.logger.warn "restore! called on #{self.class.name} but deleted_at column doesn't exist"
    end
  end

  # Check if record is soft-deleted
  def deleted?
    if self.class.column_names.include?('deleted_at')
      deleted_at.present?
    else
      false
    end
  end

  # Alias for deleted?
  def soft_deleted?
    deleted?
  end

  module ClassMethods
    # Find a record including soft-deleted ones
    def find_with_deleted(id)
      with_deleted.find(id)
    end

    # Restore multiple records
    def restore_all
      if column_names.include?('deleted_at')
        update_all(deleted_at: nil)
      else
        Rails.logger.warn "restore_all called on #{name} but deleted_at column doesn't exist"
      end
    end
  end
end
