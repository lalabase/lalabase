# frozen_string_literal: true

# Operator switch for the CodebaseHQ data import (see CodebaseImportFilePolicy).
# The importer only understands one vendor's XML export, so it is OFF for every
# organisation until an operator turns it on in the admin area.
class AddDataImportEnabledToOrganisations < ActiveRecord::Migration[8.0]
  def change
    add_column :organisations, :data_import_enabled, :boolean, default: false, null: false
  end
end
