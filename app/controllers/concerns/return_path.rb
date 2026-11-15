# frozen_string_literal: true

# What the two ways back out of an area share (navigation plan D5): the management area
# (Organisations::ManagementReturn) and the account area (AccountReturn) each keep the page
# the reader came from in the session, as the referer of the first page of the area.
#
# Only a path is kept, never a host: a referer of another host is no way back, and neither is
# a path that a browser would read as a host ("//example.com"). The session lives in a 4 KB
# encrypted cookie, so a kept path has a size limit, the same for both areas.
module ReturnPath
  # Leave room in the 4 KB encrypted session cookie for authentication and preferences.
  MAX_RETURN_PATH_BYTES = 1024

  # True for a value that may be followed as a way back: a path of this host, within the limit.
  def self.path?(value)
    value.is_a?(String) && value.start_with?('/') && !value.start_with?('//') &&
      value.bytesize <= MAX_RETURN_PATH_BYTES
  end

  private

  # The referer as a URI when it is a page of this host, else nil.
  def same_host_referer
    uri = URI.parse(request.referer.to_s)
    uri if uri.host == request.host && uri.path.to_s.start_with?('/') && !uri.path.start_with?('//')
  rescue URI::InvalidURIError
    nil
  end

  # The path and query of a URI, the form a way back is kept in.
  def return_path_of(uri)
    [uri.path, uri.query].compact.join('?')
  end

  # The controller_name of the page at `path`, nil for a path no route answers.
  def controller_name_of(path)
    Rails.application.routes.recognize_path(path)[:controller].to_s.split('/').last
  rescue ActionController::RoutingError
    nil
  end
end
