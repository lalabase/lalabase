# frozen_string_literal: true

# Entry point: .call
#
# Turns a set of filter conditions into ONE readable sentence:
#
#   "Nur Aufgaben, die offen oder in Arbeit und mir zugewiesen sind
#    und die das Etikett Kunde haben."
#
# The rule, and the whole reason this is not string concatenation:
#
#   group by the governing verb, one relative clause per verb group,
#   the verb closes its clause.
#
# Without it two things break. The German is wrong ("die offen sind und mir
# zugewiesen"), and worse, "oder" becomes ambiguous: in "mit dem Etikett Kunde
# oder dringend" it can mean a second value OR a second condition, because the
# same word carries two levels. Once the verb has closed its group, an "oder"
# behind it can only join values.
#
# The table below is the whole language model: one fragment per field plus the
# verb it governs, about ten entries, no NLP. A field with no entry falls back
# to the genitive clause, which works for every field there will ever be
# ("deren Kundennummer 4711 ist") — and project-configured attributes are
# exactly the fields nobody can enumerate in advance.
#
# The rule generalises across the two languages, the verb only sits elsewhere:
# German closes the clause with it, English opens with it right after the
# relative pronoun ("that are open or in progress"). Same table, one template
# per locale. See doc/filter_phrasen.md.
class FilterSentenceService
  # Beyond this many conditions the sentence stops binding and starts listing:
  # three commas in one breath are not read, they are skipped.
  LIST_FROM = 4

  Segment = Struct.new(:kind, :text, :category, keyword_init: true)

  # segments: the sentence in pieces, so the view can make the values
  # clickable without parsing the sentence back apart.
  # list: true when the conditions are listed instead of bound.
  Sentence = Struct.new(:segments, :list, keyword_init: true) do
    def to_s
      segments.map(&:text).join
    end

    delegate :empty?, to: :segments
  end

  GRAMMAR = {
    de: {
      lead: ->(subject) { "Nur #{subject}, " },
      clause: ->(verb, body) { "die #{body} #{verb}" },
      # warten and aufhalten carry one field each (waiting, blocking): German has no form of
      # "sein" or "haben" for them.
      verbs: { sind: 'sind', haben: 'haben', wurden: 'wurden', warten: 'warten', aufhalten: 'aufhalten' },
      # "nicht offen oder in Arbeit" can mean either thing; "weder ... noch"
      # cannot. With a single value "weder" does not exist, "nicht" does.
      negate: ->(list) { list.one? ? "nicht #{list.first}" : "weder #{list.join(' noch ')}" },
      or_word: 'oder',
      and_word: 'und',
      genitive: ->(label, body) { "deren #{label} #{body} ist" },
      list_bullet: '· '
    },
    en: {
      lead: ->(subject) { "Only #{subject} " },
      clause: ->(verb, body) { "that #{verb} #{body}" },
      # The waiting states say "are" too, but each in a clause of its own: joined to a status,
      # "that are not waiting ... and holding up ..." reads as one negated pair.
      verbs: { sind: 'are', haben: 'have', wurden: 'were', warten: 'are', aufhalten: 'are' },
      negate: ->(list) { list.one? ? "not #{list.first}" : "neither #{list.join(' nor ')}" },
      or_word: 'or',
      and_word: 'and',
      genitive: ->(label, body) { "whose #{label} is #{body}" },
      list_bullet: '· '
    }
  }.freeze

  # One entry per field: the fragment WITHOUT its verb, and the verb group it
  # belongs to. `values` gives a field its sentence forms where the menu label
  # is not one — "Heute" is a fine label for a menu and wrong in a sentence,
  # which needs "heute erstellt".
  PHRASES = {
    de: {
      'status' => { group: :sind },
      'priority' => { group: :sind, frag: ->(v) { "#{v} priorisiert" } },
      'assignee' => { group: :sind, frag: ->(v) { "#{v} zugewiesen" },
                      negate: ->(list, g) { "#{list.one? ? "#{list.first} nicht" : g[:negate].call(list)} zugewiesen" } },
      'creator' => { group: :wurden, frag: ->(v) { "von #{v} erstellt" },
                     negate: ->(list, g) { "nicht von #{list.join(" #{g[:or_word]} ")} erstellt" } },
      'tag' => { group: :haben, frag: ->(v) { "das Etikett #{v}" },
                 negate: ->(list, _g) { list.one? ? "nicht das Etikett #{list.first}" : "weder das Etikett #{list.join(' noch ')}" } },
      'created_at' => { group: :wurden, frag: ->(v) { "#{v} erstellt" },
                        values: { 'today' => 'heute', 'yesterday' => 'gestern',
                                  'last_7_days' => 'in den letzten 7 Tagen', 'last_30_days' => 'in den letzten 30 Tagen',
                                  'this_week' => 'diese Woche', 'this_month' => 'diesen Monat' } },
      'updated_at' => { group: :wurden, frag: ->(v) { "#{v} geändert" },
                        values: { 'today' => 'heute', 'yesterday' => 'gestern',
                                  'last_7_days' => 'in den letzten 7 Tagen', 'last_30_days' => 'in den letzten 30 Tagen',
                                  'this_week' => 'diese Woche', 'this_month' => 'diesen Monat' } },
      'due_date' => { group: :sind,
                      values: { 'overdue' => 'überfällig', 'due_today' => 'heute fällig',
                                'due_this_week' => 'diese Woche fällig', 'due_next_7_days' => 'in den nächsten 7 Tagen fällig' } },
      # The waiting states have one value, the flag; the fragment says the state itself.
      'waiting' => { group: :warten, frag: ->(_v) { 'auf ein offenes Ticket' },
                     negate: ->(_list, _g) { 'nicht auf ein offenes Ticket' } },
      'blocking' => { group: :aufhalten, frag: ->(_v) { 'andere Tickets' },
                      negate: ->(_list, _g) { 'andere Tickets nicht' } },
      me: 'mir'
    },
    en: {
      'status' => { group: :sind },
      'priority' => { group: :sind, frag: ->(v) { "prioritised #{v}" } },
      'assignee' => { group: :sind, frag: ->(v) { "assigned to #{v}" },
                      negate: ->(list, g) { "not assigned to #{list.join(" #{g[:or_word]} ")}" } },
      'creator' => { group: :wurden, frag: ->(v) { "created by #{v}" },
                     negate: ->(list, g) { "not created by #{list.join(" #{g[:or_word]} ")}" } },
      'tag' => { group: :haben, frag: ->(v) { "the label #{v}" },
                 negate: ->(list, _g) { list.one? ? "not the label #{list.first}" : "neither the label #{list.join(' nor ')}" } },
      'created_at' => { group: :wurden, frag: ->(v) { "created #{v}" },
                        values: { 'today' => 'today', 'yesterday' => 'yesterday',
                                  'last_7_days' => 'in the last 7 days', 'last_30_days' => 'in the last 30 days',
                                  'this_week' => 'this week', 'this_month' => 'this month' } },
      'updated_at' => { group: :wurden, frag: ->(v) { "changed #{v}" },
                        values: { 'today' => 'today', 'yesterday' => 'yesterday',
                                  'last_7_days' => 'in the last 7 days', 'last_30_days' => 'in the last 30 days',
                                  'this_week' => 'this week', 'this_month' => 'this month' } },
      'due_date' => { group: :sind,
                      values: { 'overdue' => 'overdue', 'due_today' => 'due today',
                                'due_this_week' => 'due this week', 'due_next_7_days' => 'due in the next 7 days' } },
      'waiting' => { group: :warten, frag: ->(_v) { 'waiting on an open ticket' },
                     negate: ->(_list, _g) { 'not waiting on an open ticket' } },
      'blocking' => { group: :aufhalten, frag: ->(_v) { 'holding up other tickets' },
                      negate: ->(_list, _g) { 'not holding up other tickets' } },
      me: 'me'
    }
  }.freeze

  GROUP_ORDER = %i[sind haben wurden warten aufhalten].freeze

  def self.call(**kwargs)
    new(**kwargs).call
  end

  # conditions: [{ category:, label:, values: [{ value:, label: }], operator: }]
  #   operator is 'or' (default), 'and' or 'not', exactly as the filter bar
  #   stores it.
  # me_value: the value that means the reader themselves, so the sentence can
  #   say "mir" instead of repeating their own name back at them.
  def initialize(subject:, conditions:, locale: I18n.locale, me_value: nil)
    @subject = subject
    @conditions = Array(conditions).reject { |c| Array(c[:values]).empty? }
    @locale = GRAMMAR.key?(locale.to_sym) ? locale.to_sym : :de
    @me_value = me_value
  end

  def call
    return Sentence.new(segments: [], list: false) if @conditions.empty?

    items = @conditions.map { |condition| fragment_for(condition) }
    items.length >= LIST_FROM ? listed(items) : bound(items)
  end

  private

  def grammar = GRAMMAR.fetch(@locale)
  def phrases = PHRASES.fetch(@locale)

  # One condition becomes its fragment plus the verb group it belongs to.
  # A field the table does not know keeps its own clause in the genitive.
  def fragment_for(condition)
    entry = phrases[condition[:category].to_s]
    words = value_words(condition, entry)
    negated = condition[:operator].to_s == 'not'
    joined = join_values(words, condition[:operator])

    return { genitive: true, label: condition[:label], text: joined, negated: negated, category: condition[:category] } if entry.nil?

    text =
      if negated
        entry[:negate] ? entry[:negate].call(words, grammar) : grammar[:negate].call(words)
      else
        entry[:frag] ? entry[:frag].call(joined) : joined
      end

    { group: entry[:group], text: text, category: condition[:category], values: joined }
  end

  # The words a value is said with. A date preset needs its own: "Heute" is a
  # label, "heute erstellt" is a sentence.
  def value_words(condition, entry)
    Array(condition[:values]).map do |value|
      raw = value.is_a?(Hash) ? value[:value] : value
      label = value.is_a?(Hash) ? (value[:label] || value[:value]) : value
      next phrases[:me] if @me_value && raw.to_s == @me_value.to_s && %w[assignee creator].include?(condition[:category].to_s)

      entry&.dig(:values, raw.to_s) || label.to_s
    end
  end

  def join_values(words, operator)
    word = operator.to_s == 'and' ? grammar[:and_word] : grammar[:or_word]
    join(words, word)
  end

  # "A", "A oder B", "A, B oder C": the comma carries the middle, the word
  # only the last step.
  def join(list, word)
    return list.first.to_s if list.length < 2

    "#{list[0..-2].join(', ')} #{word} #{list.last}"
  end

  # Under the threshold: group by verb, one clause per group.
  def bound(items)
    clauses = GROUP_ORDER.filter_map do |group|
      texts = items.select { |i| i[:group] == group }
      next if texts.empty?

      clause_segments(group, texts)
    end
    clauses += items.select { |i| i[:genitive] }.map { |i| genitive_segments(i) }

    segments = [Segment.new(kind: :bind, text: grammar[:lead].call(@subject))]
    clauses.each_with_index do |clause, index|
      segments << Segment.new(kind: :bind, text: separator(index, clauses.length)) if index.positive?
      segments.concat(clause)
    end
    segments << Segment.new(kind: :bind, text: '.')
    Sentence.new(segments: segments, list: false)
  end

  # From the threshold on: one clause per condition, as a list. A sentence with
  # three commas is not read, it is skipped.
  def listed(items)
    segments = [Segment.new(kind: :bind, text: grammar[:lead].call(@subject).rstrip)]
    items.each do |item|
      segments << Segment.new(kind: :bind, text: " #{grammar[:list_bullet]}")
      segments.concat(item[:genitive] ? genitive_segments(item) : clause_segments(item[:group], [item]))
    end
    Sentence.new(segments: segments, list: true)
  end

  # "die " + the fragments + " sind": the values stay their own segments, so
  # the view can hang the click on them and nothing else.
  def clause_segments(group, items)
    verb = grammar[:verbs].fetch(group)
    body = items.map { |i| i[:text] }
    whole = grammar[:clause].call(verb, join(body, grammar[:and_word]))

    split_around_values(whole, items)
  end

  def genitive_segments(item)
    whole = grammar[:genitive].call(item[:label], item[:negated] ? "nicht #{item[:text]}" : item[:text])
    split_around_values(whole, [item])
  end

  # The sentence is built as one string and then cut along its fragments, so
  # the grammar lives in ONE place and the segments cannot drift from it.
  def split_around_values(whole, items)
    segments = []
    rest = whole
    items.each do |item|
      head, _, tail = rest.partition(item[:text])
      segments << Segment.new(kind: :bind, text: head) unless head.empty?
      segments << Segment.new(kind: :value, text: item[:text], category: item[:category])
      rest = tail
    end
    segments << Segment.new(kind: :bind, text: rest) unless rest.empty?
    segments
  end

  def separator(index, total)
    return " #{grammar[:and_word]} " if index == total - 1

    ', '
  end
end
