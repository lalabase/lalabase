# frozen_string_literal: true

module Admin
  # Renders whatever is registered for a named slot of the instance admin, and
  # nothing when nobody registered. The slots and the reason they exist:
  # Lalabase::AdminExtensions.
  module ExtensionsHelper
    # For layout that depends on whether a slot brings anything, e.g. a grid
    # that would otherwise keep an empty column.
    def admin_extension_slot?(slot)
      Lalabase::AdminExtensions.partials_for(slot).any?
    end

    def admin_extension_slot(slot, **locals)
      partials = Lalabase::AdminExtensions.partials_for(slot)
      safe_join(partials.map { |partial| render(partial: partial, locals: locals) })
    end
  end
end
