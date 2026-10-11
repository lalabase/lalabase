# frozen_string_literal: true

require 'rails_helper'

# Guard: the core names no route of the operator console
# (doc/oss_core_split_plan.md 5.2, 5.6 and 10, slices S2 and S3).
#
# The admin area is split. Seven controllers (accounts, discounts, price lists,
# billing list, founder signups, founder-signup settings, acquisitions) live in
# the private engine gboyke/lalabase-operator, which only an internal process
# loads. In the public process, and on every self-hosted instance, their routes
# do not exist. A core view or mailer that calls admin_account_path there does
# not render a dead link, it RAISES: the page or the mail is gone.
#
# So the rule is: nothing in the core calls a route it does not draw itself. A
# core page that wants to show an operator section names a slot instead
# (Lalabase::AdminExtensions).
#
# Since S3.2 there is no list of operator controllers here, they are not in this
# repository. The guard runs in two modes and reads the router in both:
#
#   * The core's own CI, engine NOT loaded: every `admin_*_path`/`_url` helper
#     and every typed `/admin/<segment>` the core writes must be one the core
#     draws. An operator helper is simply an unknown name here.
#   * The engine's CI, which runs this file WITH the engine loaded: the router
#     then carries routes whose controller file is not in this repository, and
#     those are the operator's. Their names give the exact patterns, including
#     the polymorphic form ([:admin, account]) that the first mode cannot see.
#
# Three ways to reach a route, three patterns:
#   admin_account_path(account)      a named helper
#   [:admin, account]                a polymorphic array, resolved at runtime
#   '/admin/accounts'                a typed path, the only way JavaScript has
#
# What this guard cannot see: a helper name built at runtime
# (send("admin_#{x}_path")) and url_for(controller: 'admin/accounts'). Neither
# exists in the core today (checked 2026-09-21).
RSpec.describe 'Admin operator boundary' do
  # A route under admin/ whose controller is not a file of this repository is
  # drawn by an engine: the operator console, when loaded.
  def foreign_admin_controllers
    Rails.application.routes.routes.filter_map { |route| route.defaults[:controller] }
         .uniq
         .select { |controller| controller.start_with?('admin/') }
         .reject { |controller| Rails.root.join("app/controllers/#{controller}_controller.rb").exist? }
  end

  def routes_of(controllers)
    Rails.application.routes.routes.select { |route| controllers.include?(route.defaults[:controller]) }
  end

  # The fixed head of an admin path: "/admin/accounts/:id/assign_owner" and
  # "/admin/accounts(.:format)" both start with "/admin/accounts".
  def path_head(route)
    route.path.spec.to_s[%r{\A/admin/[a-z_]+}]
  end

  # The singular and plural resource names behind the helpers, for the
  # polymorphic form: admin_price_lists -> price_list, price_lists.
  def resource_names(route_names)
    route_names.map { |name| name.delete_prefix('admin_') }
               .flat_map { |name| [name, name.singularize] }
               .uniq
  end

  # A typed path in a comment is documentation, not a call. Whole-line comments
  # only: a trailing comment after code is still read.
  def comment_line?(line)
    line.lstrip.start_with?('#', '//', '*', '/*', '<%#')
  end

  def core_files
    Dir.glob(Rails.root.join('{app,lib,config}/**/*.{rb,erb,rake,js}').to_s)
       .map { |file| Pathname.new(file).relative_path_from(Rails.root).to_s }
  end

  def offenders(&check)
    core_files.each_with_object({}) do |file, found|
      hits = File.readlines(Rails.root.join(file)).each_with_index.filter_map do |line, index|
        next if comment_line?(line)

        "#{file}:#{index + 1}: #{line.strip}" if check.call(line)
      end
      found[file] = hits if hits.any?
    end
  end

  let(:foreign) { foreign_admin_controllers }
  let(:foreign_routes) { routes_of(foreign) }
  let(:foreign_names) { foreign_routes.filter_map(&:name).uniq }

  # What the core draws itself: every named route and every admin path head,
  # minus the engine's when it happens to be loaded.
  let(:core_route_names) { Rails.application.routes.named_routes.names.map(&:to_s) - foreign_names }
  let(:core_path_heads) do
    Rails.application.routes.routes.reject { |route| foreign_routes.include?(route) }
         .filter_map { |route| path_head(route) }.uniq
  end

  # Mode 1: a helper, a typed path or a polymorphic array the core does not draw.
  #
  # `[a-z_]*admin_`: a member or new action puts its name IN FRONT of the
  # namespace (new_admin_price_list_path, assign_owner_admin_account_path), and
  # `\b` does not fire between `new_` and `admin_` because `_` is a word
  # character. The first version of this guard missed exactly those (review of
  # PR #880).
  let(:helper_call) { /\b([a-z_]*admin_[a-z_]+)_(?:path|url)\b/ }
  # '/admin/accounts' but not '/admin/accounts_whatever': the head ends at a
  # character that cannot continue a path segment.
  let(:typed_path) { %r{(/admin/[a-z_]+)(?![a-z_])} }
  # [:admin, account], [:admin, :price_lists], [:admin, @organisation.account]:
  # the last identifier of the second element names the resource. The core's
  # own arrays name core resources (ai_package, beuser, prompt_persona,
  # ai_credential); anything else is suspect. A variable that hides its
  # resource ([:admin, record]) is invisible here and only a request spec finds
  # it (without_operator_extensions_spec.rb).
  let(:polymorphic_call) { /\[\s*:admin\s*,\s*:?@?([a-z_.]+)/ }
  let(:core_resources) { resource_names(core_route_names.select { |name| name.start_with?('admin_') }) }

  def unknown_helper?(line, known)
    line.scan(helper_call).flatten.any? { |name| !known.include?(name) }
  end

  def unknown_path?(line, known)
    line.scan(typed_path).flatten.any? { |head| !known.include?(head) }
  end

  def unknown_polymorphic?(line, known)
    line.scan(polymorphic_call).flatten.any? { |chain| !known.include?(chain.split('.').last) }
  end

  # Mode 2: the exact operator names, when the engine is loaded.
  let(:polymorphic_pattern) do
    names = resource_names(foreign_names).map { |name| Regexp.escape(name) }
    /\[\s*:admin\s*,[^\]]*\b(?:#{names.join('|')})\b/
  end

  it 'reads the core admin routes from the router' do
    # Without this the guard could go blind silently: an empty list of known
    # names would flag everything, an empty list of heads nothing at all.
    expect(core_route_names).to include('admin_dashboard', 'admin_organisations', 'admin_users',
                                        'admin_system_settings', 'admin_log_in')
    expect(core_path_heads).to include('/admin/organisations', '/admin/users', '/admin/system_settings')
    expect(core_route_names).not_to include('admin_accounts', 'admin_price_lists')
    expect(core_path_heads).not_to include('/admin/accounts', '/admin/price_lists')
  end

  # The checks against the forms they are meant for, so that a change to one of
  # them cannot quietly stop it from matching anything.
  it 'recognises an unknown helper, typed path and polymorphic array, and leaves core routes alone' do
    expect(unknown_helper?('link_to x, admin_account_path(account)', core_route_names)).to be(true)
    expect(unknown_helper?('link_to x, admin_price_lists_url', core_route_names)).to be(true)
    expect(unknown_helper?('link_to x, new_admin_price_list_path', core_route_names)).to be(true)
    expect(unknown_helper?('button_to x, assign_owner_admin_account_path(account)', core_route_names)).to be(true)
    expect(unknown_path?("fetch('/admin/billing_list')", core_path_heads)).to be(true)
    expect(unknown_path?("\"/admin/accounts/\#{id}\"", core_path_heads)).to be(true)
    expect(unknown_polymorphic?('redirect_to [:admin, @account]', core_resources)).to be(true)
    expect(unknown_polymorphic?('link_to x, [:admin, :price_lists]', core_resources)).to be(true)
    expect(unknown_polymorphic?('redirect_to [:admin, @organisation.account]', core_resources)).to be(true)

    core = "link_to x, admin_users_path; redirect_to [:admin, @organisation]; fetch('/admin/users'); " \
           'admin_dashboard_path; admin_log_in_path; new_admin_beuser_path; accounts; admin_extension_slot(:x); ' \
           'form_with model: [:admin, ai_package]; [:admin, @beuser]'
    expect(unknown_helper?(core, core_route_names)).to be(false)
    expect(unknown_path?(core, core_path_heads)).to be(false)
    expect(unknown_polymorphic?(core, core_resources)).to be(false)
  end

  it 'calls only route helpers, typed paths and polymorphic arrays the core draws' do
    found = offenders do |line|
      unknown_helper?(line, core_route_names) || unknown_path?(line, core_path_heads) ||
        unknown_polymorphic?(line, core_resources)
    end

    expect(found).to be_empty, <<~MESSAGE
      Core code calls a route the core does not draw. If it is a route of the
      operator console, it does not exist in the public process or on a
      self-hosted instance, so the call raises there. Render the section through
      a slot instead (Lalabase::AdminExtensions) and keep the partial in the engine.

      #{found.values.flatten.join("\n")}
    MESSAGE
  end

  context 'with the operator engine loaded (its CI runs this file)' do
    before { skip 'the engine is not loaded in this process; its own CI runs this context' if foreign.empty? }

    it 'sees the operator controllers as foreign' do
      expect(foreign).to include('admin/accounts', 'admin/account_discounts', 'admin/price_lists',
                                 'admin/billing_lists', 'admin/founder_signups', 'admin/acquisitions',
                                 'admin/founder_signup_settings')
      expect(foreign_names).to include('admin_accounts', 'admin_account', 'admin_price_lists',
                                       'admin_billing_list', 'admin_acquisition')
    end

    it 'recognises the polymorphic form' do
      expect('redirect_to [:admin, @account]').to match(polymorphic_pattern)
      expect('link_to x, [:admin, :price_lists]').to match(polymorphic_pattern)
      expect('redirect_to [:admin, @organisation.account]').to match(polymorphic_pattern)
      expect('redirect_to [:admin, @organisation]; [:admin, account_admin]; [:admin, user]').not_to match(polymorphic_pattern)
    end

    # A grep can only see NAMES. [:admin, record] with an account in `record`
    # stays invisible; that one only a request spec with an empty registry finds
    # (spec/requests/admin/without_operator_extensions_spec.rb).
    it 'finds no polymorphic route into the console' do
      found = offenders { |line| line.match?(polymorphic_pattern) }

      expect(found).to be_empty, "Core code builds an operator route from a record:\n#{found.values.flatten.join("\n")}"
    end
  end
end
