# frozen_string_literal: true

# ONE builder for "this address, with these filter changes applied": the shape
# behind every filter pill's no-JavaScript fallback href. The time list carried
# it as time_list_filter_url; the billings list (P2 of
# doc/abrechnungen_filterzeile_und_tabelle_plan.md) needs the same building
# against its own route, and a second copy of the query arithmetic is how the
# two lists would come to disagree about what clearing a filter means.
module FilterUrlHelper
  # base MUST come from a NAMED ROUTE, never from the request: to_query escapes
  # what follows the path, so nothing a visitor sends can reach the scheme
  # position of an href (the Brakeman LinkToHref reasoning documented at
  # TimeSessionsHelper#time_list_filter_url).
  #
  # nil clears a key, an Array is a multi-value key, anything else sets it.
  # A changed filter always starts again at the first page - the same rule
  # lib/query_toggle.js applies to the live address.
  def filter_url_for(base, changes = {})
    query = request.query_parameters.deep_dup
    changes.each do |key, value|
      if value.blank?
        query.delete(key.to_s)
      else
        query[key.to_s] = value
      end
    end
    query.delete('page')

    query.empty? ? base : "#{base}?#{query.to_query}"
  end
end
