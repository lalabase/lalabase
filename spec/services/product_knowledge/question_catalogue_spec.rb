# frozen_string_literal: true

require 'rails_helper'

# What:  The question catalogue of doc/product_knowledge_plan.md (D8): twenty real questions,
#        German and English, in other words than the help uses, each with the page that
#        answers it.
# Type:  MEASUREMENT over the real handbook, not part of a normal suite run.
#       Tagged :real_catalogue, so it needs a catalogue generated in
#       gboyke/lalabase-documentation and REAL_CATALOGUE=1 (see spec/rails_helper.rb).
#       The suite's own fixture is a two-page example: the handbook cannot live
#       here any more, and a measurement against two invented pages would be a
#       number about nothing.
# Why:   "As well as tickets" is measured, not assumed. The assistant reaches a help page two
#        ways: search_help by words, and help_contents, where the model picks by meaning. This
#        is the deterministic half: how many of the twenty the words alone bring among the
#        first three, and that every expected page stands in the contents with a description
#        to be chosen by. The other half, the model choosing, needs a real run (plan, S2).
RSpec.describe ProductKnowledge::Search, 'the question catalogue (D8)', :real_catalogue do
  catalogue = [
    ['de', 'Wie buche ich Zeit auf ein Ticket?', 'guides/features/time-tracking'],
    ['de', 'Wie lade ich eine Kollegin in meine Organisation ein?', 'guides/team/invite-members'],
    ['de', 'Wo stelle ich ein, wer ein Projekt sehen darf?', 'guides/team/project-access'],
    ['de', 'Wie setze ich den Status von vielen Tickets gleichzeitig?', 'guides/ticket-views/bulk-edit'],
    ['de', 'Kann ich die Oberfläche dunkel machen?', 'guides/appearance/switch-mode'],
    ['de', 'Wie stelle ich meine Stunden dem Kunden in Rechnung?', 'guides/billing/bill-time'],
    ['de', 'Ich habe keine Bestätigungsmail bekommen, was nun?', 'guides/basics/confirm-email'],
    ['de', 'Wie verbinde ich GitHub mit einem Projekt?', 'guides/repositories/connect'],
    ['de', 'Was passiert, wenn das KI-Kontingent aufgebraucht ist?', 'guides/ai/quota'],
    ['de', 'Wie halte ich ein Telefonat mit einem Kunden fest?', 'guides/meetings/basics'],
    ['de', 'Wo finde ich eine frühere Version einer Datei?', 'guides/knowledge/versioning'],
    ['de', 'Wie merke ich mir eine Ticketliste mit Filtern?', 'guides/ticket-views/saved-filters'],
    ['de', 'Wer hat die KI-Einstellungen geändert?', 'guides/ai/protocol'],
    ['de', 'Wie verbinde ich Claude Code mit Lalabase?', 'guides/ai/personal-access-tokens'],
    ['en', 'How do I log hours on a ticket?', 'guides/features/time-tracking'],
    ['en', 'How can I add a new colleague to my organisation?', 'guides/team/invite-members'],
    ['en', 'How do I switch the board to a table?', 'guides/ticket-views/configure-view'],
    ['en', 'Where do I put my own OpenAI key?', 'guides/ai/byok'],
    ['en', 'How do I turn off AI for the whole organisation?', 'guides/ai/enable-disable'],
    ['en', 'Can I bring my tickets over from CodebaseHQ?', 'guides/import/codebasehq']
  ].freeze

  # Measured when the catalogue was written (11.09.2026, on a local Postgres with the C locale;
  # CI runs UTF-8, which folds capital umlauts where C does not, and no question word starts
  # with one): 17 of 20. The three the words miss
  # are the cases help_contents exists for: a separable verb ("lade ... ein" never meets
  # "einladen"), and two questions whose words also fill longer pages ("wer ein Projekt sehen
  # darf" came fifth, "add a new colleague" seventh). No ranking variant did better: the length
  # normalizations of ts_rank_cd and a single pass over any term scored 13 to 17.
  words_alone_floor = 17

  it "brings the right page among the first three for at least #{words_alone_floor} of the 20 by words alone" do
    missed = Prosopite.pause do
      catalogue.reject do |locale, question, expected|
        described_class.new(locale: locale).query(question).first(3).map(&:slug).include?(expected)
      end
    end

    expect(catalogue.size - missed.size).to be >= words_alone_floor,
                                            "missed: #{missed.map { |_, question, page| "#{question} (#{page})" }.join('; ')}"
  end

  # Why search_help names the contents list in EVERY result instead of only in weak ones.
  #
  # After the first real run (12.09.2026) the obvious fix was a signal: when no page carries
  # every search word, say so and send the model to the contents list. Measuring it on the
  # catalogue killed it. Of the three questions the words miss, every one has another page that
  # carries every word (the assistant page for both invite questions, a longer page for the
  # project rights), so the signal would have stayed quiet exactly where the search fails. And
  # four questions whose page comes first or third have no such page at all, so it would have
  # fired where the search works.
  #
  # Whether a hit answers the question is a judgement about meaning. This guard keeps the
  # measurement that says no property of the hits stands in for it.
  it 'shows that the match kind does not separate a good result from a bad one' do
    measured = Prosopite.pause do
      catalogue.map do |locale, question, expected|
        hits = described_class.new(locale: locale).query(question)
        { right_page: hits.first(3).map(&:slug).include?(expected),
          every_word: hits.any? { |hit| hit.match == described_class::ALL_TERMS } }
      end
    end
    missed, found = measured.partition { |row| !row[:right_page] }

    expect(missed.pluck(:every_word)).to all(be(true)), 'a miss without every word: the signal would work'
    expect(found.pluck(:every_word)).to include(false), 'no hit lacks every word: the signal would be free'
  end

  it 'holds every expected page in the contents of its language, with a description to choose it by' do
    contents = Prosopite.pause do
      Docs::Contract::LOCALES.index_with { |locale| described_class.new(locale: locale).contents.index_by(&:slug) }
    end

    catalogue.each do |locale, question, expected|
      expect(contents.fetch(locale)[expected]&.description).to be_present,
                                                               "#{question}: #{expected} has no description in the #{locale} contents"
    end
  end
end
