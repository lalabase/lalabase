# frozen_string_literal: true

module Wiki
  # Single home for "what is a mention in the stored HTML". Shared by the
  # MarkdownSerializer (turns mentions into links) and the ReferenceExtractor
  # (turns mentions into the link index) so the scan never drifts between them.
  #
  # A mention is an ActionText attachment whose content-type ends in "mention"
  # (e.g. application/vnd.actiontext.mention).
  module Mention
    CONTENT_TYPE_SUFFIX = 'mention'
    ATTACHMENT_SELECTOR = 'action-text-attachment'

    # The mention attachment nodes within an already-parsed Nokogiri fragment.
    def self.nodes(fragment)
      fragment.css(ATTACHMENT_SELECTOR).select do |node|
        node['content-type'].to_s.end_with?(CONTENT_TYPE_SUFFIX)
      end
    end
  end
end
