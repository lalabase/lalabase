# frozen_string_literal: true

# Enable `assigns(...)` and template/integration helpers in request specs.
# `rails-controller-testing` ships them for controller specs by default; this
# include block extends the support to type: :request specs that still rely on
# `assigns` for inspecting controller-set ivars.
require 'rails-controller-testing'

# Rails 8 stripped `assigns` from request specs; ActionDispatch::TestProcess
# raises NoMethodError by default. The rails-controller-testing gem replaces
# this with a working implementation, but its on_load hooks don't fire in
# our boot. Patch the module directly so `assigns(:ivar)` works in request
# specs that still depend on it.
ActionDispatch::TestProcess.module_eval do
  def assigns(key = nil)
    assigns = {}.with_indifferent_access
    @controller&.view_assigns&.each { |k, v| assigns.regular_writer(k, v) }
    key.nil? ? assigns : assigns[key]
  end
end
