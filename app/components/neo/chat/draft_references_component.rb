# frozen_string_literal: true

module Neo
  module Chat
    # References selected before a thread exists. The form carries keys only;
    # labels on a failed submission are resolved again against current access.
    class DraftReferencesComponent < ViewComponent::Base
      def initialize(chat:, current_user:)
        super()
        @chat = chat
        @current_user = current_user
      end

      def references
        @references ||= Lalabase::Tools::Scope.for(chat: @chat, actor: @current_user)&.references || []
      end

      def title_for(record)
        Assistant::ReferenceRegistry.entry_for(record.class.name)
                                    .title.call(record, Neo::Chat::ReferenceChipComponent::MAX_TITLE_CHARS)
      end

      def reference_keys
        references.map { |record| Assistant::ReferenceRegistry.key_of(record) }.join(' ')
      end
    end
  end
end
