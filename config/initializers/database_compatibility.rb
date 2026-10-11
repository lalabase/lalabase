# frozen_string_literal: true

# This initializer ensures database compatibility when columns might be missing
# Useful for staged deployments where migrations haven't been run yet

Rails.application.config.after_initialize do
  # Check if we're in a web/console environment (not rake tasks)
  # Skip during asset precompilation and other rake tasks that don't need DB
  if defined?(Rails::Server) || defined?(Rails::Console)

    # Monkey-patch Ticket model if number column is missing
    if ActiveRecord::Base.connection.table_exists?('tickets') && !ActiveRecord::Base.connection.column_exists?(:tickets, :number)
      Rails.logger.warn "⚠️  Column 'number' missing from tickets table - applying compatibility patch"

      Ticket.class_eval do
        # Override display_title to work without number
        def display_title
          if respond_to?(:number) && number.present?
            "##{number} #{title}"
          else
            title
          end
        end

        # Make number-related callbacks safe
        def assign_next_number
          # No-op if column doesn't exist
        end

        def number_presence_after_create
          # No-op if column doesn't exist
        end
      end
    end

    # Monkey-patch User model if deleted_at column is missing
    if ActiveRecord::Base.connection.table_exists?('users') && !ActiveRecord::Base.connection.column_exists?(:users, :deleted_at)
      Rails.logger.warn "⚠️  Column 'deleted_at' missing from users table - applying compatibility patch"

      # Remove default_scope from SoftDeletable if included
      if User.included_modules.include?(SoftDeletable)
        User.class_eval do
          # Remove the default scope
          self.default_scopes = []

          # Add safe versions of the scopes
          scope :deleted, -> { none }
          scope :with_deleted, -> { all }
          scope :only_deleted, -> { none }

          # Override soft delete methods
          def soft_delete!
            destroy!
          end

          def deleted?
            false
          end
        end
      end
    end

    # Monkey-patch Post model if privacy columns are missing
    if ActiveRecord::Base.connection.table_exists?('posts') && !ActiveRecord::Base.connection.column_exists?(:posts, :is_private)
      Rails.logger.warn "⚠️  Column 'is_private' missing from posts table - applying compatibility patch"

      Post.class_eval do
        # Safe versions of privacy methods
        def private?
          false
        end

        def public?
          true
        end

        def readable_by?(_user)
          true
        end

        # Safe version of the scope
        scope :readable_by, ->(_user, _organisation) { all }
        scope :public_posts, -> { all }
        scope :private_posts, -> { none }
      end
    end

    Rails.logger.info '✅ Database compatibility patches applied successfully'
  end
rescue StandardError => e
  Rails.logger.error "❌ Error applying database compatibility patches: #{e.message}"
  # Don't prevent app startup
end
