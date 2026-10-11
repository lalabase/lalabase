# frozen_string_literal: true

require 'rails_helper'

# The instance admin as the PUBLIC process serves it: nothing registered for any
# slot (doc/oss_core_split_plan.md 5.2 and 5.6, slice S2).
#
# The operator console is an engine that only an internal process loads. Every
# other process, and every self-hosted instance, renders these pages without it.
# The pages that carry an operator section must therefore work with an empty
# registry, and must not show a trace of the section: no link into the console,
# no heading without content, no empty grid column.
#
# The counterpart, "with the engine loaded the sections are there", lives in
# the engine: spec/requests/admin/operator_extensions_spec.rb of
# gboyke/lalabase-operator asserts the same anchors present that this file
# asserts absent (id="billing-accounts", id="billing-account",
# id="founder-signup-settings", the four operator paths). Since S3.2 the core
# registers nothing itself, so "with nothing registered" is what this process
# is; the empty-registry block stays so that a core initializer registering
# something again would be caught by it.
RSpec.describe 'Admin area without operator extensions', type: :request do
  let(:admin_beuser) { create(:beuser) }
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before do
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
  end

  # The anchors below are not negative in a vacuum: the engine's spec renders
  # the same pages with the sections registered and finds every one of them.
  context 'with nothing registered' do
    around { |example| Lalabase::AdminExtensions.with_empty_registry { example.run } }

    # Paths rather than labels: a label can be renamed, and the word "Konto" also
    # appears in core texts ("Konto löschen" on the user page).
    operator_paths = %w[/admin/accounts /admin/price_lists /admin/billing_list /admin/acquisition
                        /admin/founder_signup_settings].freeze

    shared_examples 'a page without a trace of the console' do
      it 'renders, and links nowhere into the console' do
        get path

        expect(response).to have_http_status(:ok)
        operator_paths.each { |operator_path| expect(response.body).not_to include(operator_path) }
      end
    end

    describe 'dashboard' do
      let(:path) { admin_dashboard_path }

      it_behaves_like 'a page without a trace of the console'

      it 'lays its own three tiles out in three columns, not four with a hole' do
        get path

        management = response.body[%r{#{Regexp.escape(I18n.t('admin.dashboard.group_management'))}.*?</section>}m]
        expect(management).to include('lg:grid-cols-3')
        expect(management).not_to include('lg:grid-cols-4')
      end
    end

    describe 'organisation page' do
      let(:path) { admin_organisation_path(organisation) }

      it_behaves_like 'a page without a trace of the console'

      it 'does not name a billing account' do
        get path

        expect(response.body).not_to include('id="billing-account"')
      end
    end

    describe 'user page' do
      let(:path) { admin_user_path(user) }

      it_behaves_like 'a page without a trace of the console'

      it 'has no billing accounts section' do
        get path

        expect(response.body).not_to include('id="billing-accounts"')
      end
    end

    describe 'system settings' do
      let(:path) { admin_system_settings_path }

      it_behaves_like 'a page without a trace of the console'

      # The four blocks that are the instance's own stay; the founder block is gone
      # together with the form that posted to the console.
      it 'keeps its own blocks and has no founder-request block' do
        get path

        expect(response.body).to include('id="legal-identity-settings"', 'id="registration-settings"')
        expect(response.body).not_to include('founder-signup-settings', 'founder_signup')
      end
    end

    describe 'organisation list, for the menu' do
      let(:path) { admin_organisations_path }

      it_behaves_like 'a page without a trace of the console'
    end
  end
end
