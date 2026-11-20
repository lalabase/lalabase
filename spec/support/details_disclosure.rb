# frozen_string_literal: true

# Whether the <details> elements of a response are open, read from the parsed markup.
#
#   expect(details_open_states(response.body)).to eq([true])
#
# Not a regex over the tag: an attribute value may hold a ">" (a Stimulus action such as
# `toggle->neo-disclosure#toggled`), and `/<details[^>]*\sopen/` stops there. After #244 gave
# the reference list that action, three specs that wanted the list open turned red and the
# one that wanted it closed stayed green without reading the attribute at all.
#
# Libxml's HTML parser keeps the children of a turbo-stream <template> as ordinary nodes, so
# the body of a stream reads like a page.
module DetailsDisclosure
  def details_open_states(body)
    Nokogiri::HTML(body).css('details').map { |details| details.key?('open') }
  end
end

RSpec.configure do |config|
  config.include DetailsDisclosure, type: :request
end
