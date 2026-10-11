# frozen_string_literal: true

require 'rails_helper'

# ONE gate for the whole admin area: Admin::Authentication#require_login refuses
# every beuser that is not an active admin, on every request, before any filter
# of a subclass runs.
#
# Until 2026-09-22 four controllers (acquisitions, deletion_registers,
# system_settings, user_activities) carried a hand-copied `require_admin!` on top
# of it, and the second half of S2 was about to add a fifth. None of them could
# ever fire: by the time a subclass filter runs, current_user IS an active admin.
# They were deleted, and this spec is what would have caught a real gap: it
# knocks on the pages that used to carry the copy, after the session's beuser
# was demoted or deactivated behind its back.
RSpec.describe 'Admin area: the admin gate lives in the base controller', type: :request do
  let(:beuser) { create(:beuser) } # factory: role 'admin', active

  # The pages that used to carry their own copy of the gate. The fourth,
  # acquisitions, is a page of the operator console since S3.2 and no route of
  # this process; its controller inherits the same base and the same gate.
  formerly_double_gated = {
    'deletion register' => -> { admin_deletion_register_path },
    'system settings' => -> { admin_system_settings_path },
    'user activities' => -> { admin_user_activities_path }
  }

  before do
    post admin_log_in_path, params: { email: beuser.email, password: beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  shared_examples 'refused at the door' do
    formerly_double_gated.each do |name, path|
      it "is sent to the login instead of the #{name}" do
        get instance_exec(&path)

        expect(response).to redirect_to(admin_log_in_path)
      end
    end
  end

  # The control: the same pages, for the same session, before anything changes.
  # One example per page, not a loop: Prosopite reads four requests that each
  # load the session's beuser once as an N+1.
  formerly_double_gated.each do |name, path|
    it "lets an active admin into the #{name}" do
      get instance_exec(&path)

      expect(response).to have_http_status(:ok)
    end
  end

  context 'after the beuser lost the admin role mid-session' do
    # Another active admin does it: the last one cannot lose the role (Beuser).
    before do
      create(:beuser)
      beuser.update!(role: 'user')
    end

    it_behaves_like 'refused at the door'
  end

  context 'after the beuser was deactivated mid-session' do
    before do
      create(:beuser)
      beuser.update!(active: false)
    end

    it_behaves_like 'refused at the door'
  end
end
