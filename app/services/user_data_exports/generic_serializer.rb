# frozen_string_literal: true

module UserDataExports
  # Turns a Registry source into an array of whitelisted hashes. Strictly
  # declarative: emits exactly source.attributes (column reads) plus
  # source.computed (association lookups declared in the registry) — never a
  # full row, never as_json. Sources with real logic (joins, filtering) use a
  # dedicated serializer class instead (Registry serializer: option).
  class GenericSerializer
    ATTRIBUTES = [].freeze # dedicated serializers declare theirs; generic reads the source

    def self.call(source, user)
      rows = []
      source.scope.call(user).find_each(batch_size: 500) do |record|
        rows << serialize(source, record)
      end
      rows
    end

    def self.serialize(source, record)
      row = {}
      source.attributes.each { |attr| row[attr] = record.public_send(attr) }
      source.computed.each { |key, blk| row[key.to_s] = blk.call(record) }
      row
    end
  end
end
