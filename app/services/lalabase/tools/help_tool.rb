# frozen_string_literal: true

module Lalabase
  module Tools
    # What the three tools that read Lalabase's own help share (doc/product_knowledge_plan.md,
    # S2): search_help finds pages by words, help_contents lists every page for the model to
    # choose from by meaning (D7), get_help_page reads one. All three read through
    # ProductKnowledge::Search, the one reader of the table.
    #
    # The help is the same for every organisation and has no rights of its own: whoever may log
    # in may read /hilfe. So none of the three narrows by project, asks Pundit or reports a
    # coverage, and their citations carry no area (Citations.help_page), which leaves an answer
    # drawn only on the help ungated, the way the code layer is.
    #
    # What they do take from the asker is the LANGUAGE: language_preference, the language the
    # person chose for the interface and therefore reads the help in. Not chat.language: that is
    # a detector's guess, locked on the first question, and it answers "en" for "Zeit buchen".
    # A value Search does not know falls back to the help's own default
    # (Docs::Contract::DEFAULT_LOCALE), the one owner of that rule.
    class HelpTool < Base
      # Reads context.actor for the language, so the Runner's fail-closed bar applies: a thread
      # without an asker has nobody whose language the help could be read in.
      def self.requires_actor?
        true
      end

      def self.help_search(context)
        ProductKnowledge::Search.new(locale: context.actor.language_preference)
      end

      # The head of a page as all three tools hand it to the model: what it is called, where it
      # sits and what it is about. One place chooses these fields, so the three cannot drift.
      def self.page_head(page)
        { slug: page.slug, title: page.title, section: page.section, description: page.description }
      end

      # What a read that found nothing answers: its own empty answer when the help is there,
      # otherwise that the help is not available.
      def self.nothing_found(search, answer)
        search.available? ? answer : unavailable(locale: search.locale)
      end

      # The table holds nothing yet: the first sync has not committed (a fresh install, while
      # another process holds the lock) or the table was emptied. An ERROR, not an empty
      # success: "no help page matches" would be a false statement the model passes on, where
      # "not available right now" is true and keeps it from answering from memory (review of
      # the S2 PR).
      # Two different situations, and telling them apart matters to the model:
      # an index that is still filling will answer in a moment, an instance
      # without a catalogue never will. Saying "it may still be loading" there
      # is permanently untrue and invites the model to try again forever.
      #
      # Registry keeps these tools out of the set entirely when there is no
      # catalogue, so the second branch is the narrow case where the index is
      # empty although a catalogue exists.
      def self.unavailable(locale: Docs::Contract::DEFAULT_LOCALE)
        return no_catalogue(locale: locale) unless Docs::Catalogue.available?

        Result.new(error: 'The help is not available right now, it may still be loading. Say that ' \
                          'you could not read the help, and do not answer from memory.')
      end

      # The address in the reader's own language: the tool knows it from the
      # asker, and sending an English reader to the German handbook is a small
      # thing that reads as carelessness.
      def self.no_catalogue(locale: Docs::Contract::DEFAULT_LOCALE)
        Result.new(error: 'This instance does not carry the handbook. Say that you cannot read ' \
                          "it here, point to #{Docs::PublicDocs.url(locale: locale)}, " \
                          'and do not answer from memory.')
      end
    end
  end
end
