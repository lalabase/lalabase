# frozen_string_literal: true

require 'rails_helper'

# Guard: no admin controller carries its own admin check.
#
# Admin::Authentication#require_login, included by Admin::ApplicationController,
# refuses every beuser that is not an active admin on every request. A
# `require_admin!` in a subclass can therefore never fire; four controllers
# carried one anyway until 2026-09-22, each copied by hand, and a fifth was on
# its way. What the gate does is pinned in
# spec/requests/admin/admin_only_gate_spec.rb.
RSpec.describe 'Admin gate is not copied into controllers' do
  it 'finds no require_admin in app/controllers/admin' do
    files = Dir.glob(Rails.root.join('app/controllers/admin/**/*.rb').to_s)
    offenders = files.select { |file| File.read(file).match?(/\brequire_admin!?\b/) }
                     .map { |file| Pathname.new(file).relative_path_from(Rails.root).to_s }

    expect(offenders).to be_empty, <<~MESSAGE
      An admin controller defines or calls its own admin check. It cannot fire:
      Admin::Authentication#require_login already refuses every beuser that is
      not an active admin, before any subclass filter runs. Delete it.

      #{offenders.join("\n")}
    MESSAGE
  end
end
