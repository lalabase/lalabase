# frozen_string_literal: true

# The SHA git gives a file's content (`git hash-object`), computed in Ruby so that no
# shell-out per file is needed. The sync uses it to tell whether a page or an image
# changed since the last run.
#
# Entry point: sha
module Documentation
  module GitBlob
    module_function

    # The header counts BYTES, not characters.
    def sha(content)
      bytes = content.to_s.b
      Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0".b + bytes)
    end
  end
end
