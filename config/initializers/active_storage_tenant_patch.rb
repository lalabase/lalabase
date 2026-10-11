# frozen_string_literal: true

# config/initializers/active_storage_tenant_patch.rb
# This initializer patches ActiveStorage to work with multi-tenancy through acts_as_tenant.
#
# Every bypass here is THREAD-LOCAL via ActsAsTenant.without_tenant. Until 2026-08-23 the
# helpers flipped `ActsAsTenant.configuration.require_tenant = false`, a process-wide
# switch: on multi-threaded Puma every parallel request lost the tenant requirement for
# as long as any ActiveStorage request was running (spike plan E4, second review). The
# middleware ActiveStorageTenantBypass (config/initializers/acts_as_tenant.rb) covers the
# same requests from outside; both stay, belt and braces, and neither touches the
# configuration. Guard: spec/requests/active_storage/tenant_bypass_in_controller_spec.rb

Rails.application.config.to_prepare do
  # Only run this code if ActiveStorage and acts_as_tenant are defined
  if defined?(ActiveStorage) && defined?(ActsAsTenant)
    # Thread-local bypass for the patched finders below.
    module TenantBypassHelper
      def without_tenant(&)
        ActsAsTenant.without_tenant(&)
      end
    end

    # Patch for model classes
    if defined?(ActiveStorage::Blob) && defined?(ActiveStorage::Attachment)
      # Apply the patch to relevant ActiveStorage model classes
      [ActiveStorage::Blob, ActiveStorage::Attachment].each do |model_class|
        model_class.extend(TenantBypassHelper)

        # Override the find method to bypass tenant requirements
        model_class.class_eval do
          class << self
            alias_method :original_find, :find

            def find(id)
              without_tenant { original_find(id) }
            end
          end
        end
      end
    end

    # Controller concern for bypassing tenant requirement
    module BypassTenantForActiveStorage
      extend ActiveSupport::Concern

      included do
        around_action :bypass_acts_as_tenant, prepend: true
      end

      def bypass_acts_as_tenant(&)
        ActsAsTenant.without_tenant(&)
      end
    end

    # More reliable approach to patch all ActiveStorage controllers
    if defined?(ActiveStorage::BaseController)
      # Patch the base controller - this will apply to all subclasses
      ActiveStorage::BaseController.include(BypassTenantForActiveStorage)
    end

    # Try to patch potential controller classes if they exist
    # This is more flexible in case of Rails version differences
    [
      'ActiveStorage::Representations::BaseController',
      'ActiveStorage::Blobs::BaseController',
      'ActiveStorage::DiskController',
      'ActiveStorage::BlobsController',
      'ActiveStorage::DirectUploadsController'
      # Add any other controllers that might exist in Rails 8
    ].each do |controller_name|
      if (controller_class = controller_name.safe_constantize) && !(controller_class < BypassTenantForActiveStorage)
        controller_class.include(BypassTenantForActiveStorage)
      end
    end
  end
end
