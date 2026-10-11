# frozen_string_literal: true

# The imprint, privacy policy and terms of THIS instance, when its operator
# wrote them here instead of hosting them elsewhere.
#
# The core has no legal pages of its own and never will: what they must say
# depends on who runs the instance and where. An operator with a website links
# it (LegalIdentity#url_for, which wins). An operator without one -- an internal
# team tool is the normal case -- writes the text in the admin area, and this
# serves it.
#
# Reachable without signing in, because the login page links here and somebody
# who cannot sign in is exactly who may need to read the privacy policy.
class LegalPagesController < ApplicationController
  layout 'application_sessionless'

  skip_before_action :authenticate_user!
  skip_before_action :load_tenant_from_session

  def show
    @page = params[:page].to_sym
    @body = LegalIdentity.current.body_for(@page)

    # No text means this instance does not host the page. Not a 403 and not an
    # empty page: the address simply has nothing behind it here.
    return head :not_found if @body.blank?

    @title = t("views.shared.legal.#{@page}")
  end
end
