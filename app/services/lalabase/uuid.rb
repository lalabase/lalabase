# frozen_string_literal: true

# The ONE spelling of "is this string a UUID" for a value that reaches a uuid
# column from outside (an MCP argument, an API parameter). It matters because
# ActiveRecord casts a malformed value to NULL instead of raising: an unchecked
# filter `where(project_id: 'abc')` silently becomes `project_id IS NULL`, the
# project-less rows, the opposite of what was asked. Tools::Base::UUID_FORMAT
# is an alias of FORMAT so the tools keep their spelling.
#
# Entry point: valid?
module Lalabase
  module Uuid
    FORMAT = /\A(\h{8}-\h{4}-\h{4}-\h{4}-\h{12}|\h{32})\z/

    def self.valid?(value)
      value.to_s.match?(FORMAT)
    end

    # The dashed, lowercase spelling and nothing else: what Postgres hands back
    # for a uuid column, and therefore the ONE spelling a stored id may take.
    CANONICAL = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    # The canonical spelling of a value, or nil. For a UUID that becomes part of
    # an IDENTITY compared as a string (the assistant's reference key
    # "Ticket:<uuid>"): "ABC..." and "abc..." name the same row to Postgres, but
    # not to a Hash lookup. The 32-hex form is refused rather than re-dashed --
    # nothing in this app produces it.
    def self.canonical(value)
      spelled = value.to_s.downcase
      spelled if spelled.match?(CANONICAL)
    end

    # The canonical spelling of ANY value valid? lets in, the 32-hex form
    # re-dashed, or nil. For an id taken from outside and then looked up as a
    # string (Notifications::InboxQuery's organisation_id against the ids it
    # loaded): what valid? accepts must name the row it names to Postgres.
    def self.dashed(value)
      raw = value.to_s.strip.downcase
      return nil unless raw.match?(FORMAT)
      return raw if raw.include?('-')

      [raw[0, 8], raw[8, 4], raw[12, 4], raw[16, 4], raw[20, 12]].join('-')
    end
  end
end
