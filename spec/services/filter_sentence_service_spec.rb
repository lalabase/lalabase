# frozen_string_literal: true

require 'rails_helper'

# What: the grammar of the readable filter (FilterSentenceService).
# Type: unit spec, no database.
# Why: the sentence is the resting state of the filter bar (Vorschlag 20a), so
#   it is read far more often than the conditions are edited. Every expected
#   sentence below is written BY HAND from the rule and not taken from the
#   implementation: a sentence the machine dictated to itself proves nothing.
#   The rule is: group by governing verb, one relative clause per group, the
#   verb closes the clause.
RSpec.describe FilterSentenceService do
  def cond(category, values, label: nil, operator: 'or')
    values = Array(values).map { |v| v.is_a?(Hash) ? v : { value: v, label: v } }
    { category: category, label: label || category.to_s.humanize, values: values, operator: operator }
  end

  def sentence(conditions, subject: 'Aufgaben', locale: :de, me_value: nil)
    described_class.call(subject: subject, conditions: conditions, locale: locale, me_value: me_value).to_s
  end

  let(:me) { { value: 'u-1', label: 'Guido Boyke' } }
  let(:other) { { value: 'u-2', label: 'Tina Klar' } }

  describe 'binding under the threshold' do
    it 'says one condition' do
      expect(sentence([cond('status', 'offen')]))
        .to eq('Nur Aufgaben, die offen sind.')
    end

    it 'joins two values of one field with "oder"' do
      expect(sentence([cond('status', ['offen', 'in Arbeit'])]))
        .to eq('Nur Aufgaben, die offen oder in Arbeit sind.')
    end

    it 'says the reader as "mir", not by their own name' do
      expect(sentence([cond('assignee', [me])], me_value: 'u-1'))
        .to eq('Nur Aufgaben, die mir zugewiesen sind.')
    end

    it 'puts two conditions of the same verb group into ONE clause' do
      expect(sentence([cond('status', ['offen', 'in Arbeit']), cond('assignee', [me])], me_value: 'u-1'))
        .to eq('Nur Aufgaben, die offen oder in Arbeit und mir zugewiesen sind.')
    end

    it 'takes a comma between three fragments of one group and the word only before the last' do
      expect(sentence([cond('status', ['offen', 'in Arbeit']), cond('assignee', [me]), cond('due_date', 'overdue')],
                      me_value: 'u-1'))
        .to eq('Nur Aufgaben, die offen oder in Arbeit, mir zugewiesen und überfällig sind.')
    end

    it 'opens a second clause for a second verb group' do
      expect(sentence([cond('status', 'offen'), cond('tag', 'Kunde')]))
        .to eq('Nur Aufgaben, die offen sind und die das Etikett Kunde haben.')
    end

    it 'uses the third verb group for what was done to the ticket' do
      expect(sentence([cond('creator', [me])]))
        .to eq('Nur Aufgaben, die von Guido Boyke erstellt wurden.')
    end

    it 'separates three clauses with a comma and one "und"' do
      expect(sentence([cond('status', 'offen'), cond('tag', 'Kunde'), cond('creator', [me])]))
        .to eq('Nur Aufgaben, die offen sind, die das Etikett Kunde haben und die von Guido Boyke erstellt wurden.')
    end

    it 'says "und" between values where the operator is and, not or' do
      expect(sentence([cond('tag', %w[Kunde dringend], operator: 'and')]))
        .to eq('Nur Aufgaben, die das Etikett Kunde und dringend haben.')
    end

    it 'gives a date preset its sentence form, not its menu label' do
      expect(sentence([cond('created_at', 'this_week')]))
        .to eq('Nur Aufgaben, die diese Woche erstellt wurden.')
    end

    it 'binds two conditions of the "wurden" group' do
      expect(sentence([cond('updated_at', 'today'), cond('creator', [me])]))
        .to eq('Nur Aufgaben, die heute geändert und von Guido Boyke erstellt wurden.')
    end

    it 'says a priority as an adverb' do
      expect(sentence([cond('priority', 'hoch')]))
        .to eq('Nur Aufgaben, die hoch priorisiert sind.')
    end
  end

  describe 'negation' do
    it 'says "nicht" for a single value' do
      expect(sentence([cond('status', 'erledigt', operator: 'not')]))
        .to eq('Nur Aufgaben, die nicht erledigt sind.')
    end

    # "nicht offen oder in Arbeit" can mean either thing. This cannot.
    it 'says "weder ... noch" for a list' do
      expect(sentence([cond('status', ['offen', 'in Arbeit'], operator: 'not')]))
        .to eq('Nur Aufgaben, die weder offen noch in Arbeit sind.')
    end

    it 'keeps the field word in a negated tag' do
      expect(sentence([cond('tag', 'Kunde', operator: 'not')]))
        .to eq('Nur Aufgaben, die nicht das Etikett Kunde haben.')
    end

    it 'says a negated tag list without repeating the field word' do
      expect(sentence([cond('tag', %w[Kunde dringend], operator: 'not')]))
        .to eq('Nur Aufgaben, die weder das Etikett Kunde noch dringend haben.')
    end

    it 'moves the "nicht" behind the person, where German wants it' do
      expect(sentence([cond('assignee', [me], operator: 'not')], me_value: 'u-1'))
        .to eq('Nur Aufgaben, die mir nicht zugewiesen sind.')
    end

    it 'says a negated list of people as "weder ... noch"' do
      expect(sentence([cond('assignee', [me, other], operator: 'not')], me_value: 'u-1'))
        .to eq('Nur Aufgaben, die weder mir noch Tina Klar zugewiesen sind.')
    end

    it 'negates the creator in front of the person' do
      expect(sentence([cond('creator', [me], operator: 'not')]))
        .to eq('Nur Aufgaben, die nicht von Guido Boyke erstellt wurden.')
    end
  end

  describe 'a field the table does not know' do
    # Project-configured attributes are exactly the fields nobody can list in
    # advance. The genitive clause works for every one of them.
    it 'falls back to the genitive clause' do
      expect(sentence([cond('kundennummer', '4711', label: 'Kundennummer')]))
        .to eq('Nur Aufgaben, deren Kundennummer 4711 ist.')
    end

    it 'keeps its own clause next to a known field' do
      expect(sentence([cond('status', 'offen'), cond('kundennummer', '4711', label: 'Kundennummer')]))
        .to eq('Nur Aufgaben, die offen sind und deren Kundennummer 4711 ist.')
    end
  end

  describe 'from four conditions on' do
    it 'lists instead of binding' do
      conditions = [cond('status', ['offen', 'in Arbeit']), cond('assignee', [me]),
                    cond('due_date', 'overdue'), cond('tag', 'Kunde')]

      expect(sentence(conditions, me_value: 'u-1'))
        .to eq('Nur Aufgaben, · die offen oder in Arbeit sind · die mir zugewiesen sind ' \
               '· die überfällig sind · die das Etikett Kunde haben')
    end

    it 'marks the result as a list, so the view can set it as one' do
      conditions = [cond('status', 'offen'), cond('assignee', [me]),
                    cond('due_date', 'overdue'), cond('tag', 'Kunde')]

      expect(described_class.call(subject: 'Aufgaben', conditions: conditions).list).to be true
    end
  end

  describe 'the pieces the view needs' do
    it 'hands the values back as their own segments, with the field they belong to' do
      result = described_class.call(
        subject: 'Aufgaben',
        conditions: [cond('status', ['offen', 'in Arbeit']), cond('tag', 'Kunde')]
      )
      values = result.segments.select { |s| s.kind == :value }

      expect(values.map(&:text)).to eq(['offen oder in Arbeit', 'das Etikett Kunde'])
      expect(values.map(&:category)).to eq(%w[status tag])
    end

    it 'is empty without a condition, so the row can disappear entirely' do
      expect(described_class.call(subject: 'Aufgaben', conditions: [])).to be_empty
    end

    it 'drops a condition that carries no value' do
      expect(sentence([cond('status', 'offen'), { category: 'tag', label: 'Tags', values: [] }]))
        .to eq('Nur Aufgaben, die offen sind.')
    end
  end

  # The rule survives the language change, the verb only stands elsewhere:
  # German closes the clause with it, English opens with it.
  describe 'English' do
    it 'puts the verb behind the relative pronoun' do
      expect(sentence([cond('status', ['open', 'in progress']), cond('assignee', [me]), cond('tag', 'Kunde')],
                      subject: 'tasks', locale: :en, me_value: 'u-1'))
        .to eq('Only tasks that are open or in progress and assigned to me and that have the label Kunde.')
    end

    it 'says "neither ... nor"' do
      expect(sentence([cond('status', ['open', 'in progress'], operator: 'not')], subject: 'tasks', locale: :en))
        .to eq('Only tasks that are neither open nor in progress.')
    end

    it 'lists from four conditions on' do
      conditions = [cond('status', 'open'), cond('assignee', [me]), cond('due_date', 'overdue'), cond('tag', 'Kunde')]

      expect(sentence(conditions, subject: 'tasks', locale: :en, me_value: 'u-1'))
        .to eq('Only tasks · that are open · that are assigned to me · that are overdue · that have the label Kunde')
    end
  end

  # The waiting states (doc/ticket_relations_plan.md, revision 4, §9). One value, the flag, and
  # the menu label is no sentence: the fragment is fixed. German needs a verb of its own for
  # each, so each opens its own clause. English says them with "are", but in a clause of their
  # own as well: joined to a status, "not" would read as covering the whole list (review of #950).
  describe 'the waiting states' do
    def flag(category, operator: 'or')
      cond(category, [{ value: 'true', label: 'Wartet auf offenes Ticket' }], operator: operator)
    end

    it 'says "warten" for waiting' do
      expect(sentence([flag('waiting')])).to eq('Nur Aufgaben, die auf ein offenes Ticket warten.')
    end

    it 'puts the "nicht" in front of what they wait on' do
      expect(sentence([flag('waiting', operator: 'not')])).to eq('Nur Aufgaben, die nicht auf ein offenes Ticket warten.')
    end

    it 'says "aufhalten" for blocking, negated behind the object' do
      expect(sentence([flag('blocking')])).to eq('Nur Aufgaben, die andere Tickets aufhalten.')
      expect(sentence([flag('blocking', operator: 'not')])).to eq('Nur Aufgaben, die andere Tickets nicht aufhalten.')
    end

    it 'gives each state its own clause next to a status' do
      expect(sentence([cond('status', 'offen'), flag('waiting'), flag('blocking', operator: 'not')]))
        .to eq('Nur Aufgaben, die offen sind, die auf ein offenes Ticket warten und die andere Tickets nicht aufhalten.')
    end

    it 'hands the fragment back as the value segment of its field' do
      result = described_class.call(subject: 'Aufgaben', conditions: [flag('waiting')])
      expect(result.segments.select { |segment| segment.kind == :value }.map { |segment| [segment.text, segment.category] })
        .to eq([['auf ein offenes Ticket', 'waiting']])
    end

    it 'says both with "are" in English, each in a clause of its own' do
      expect(sentence([flag('waiting')], subject: 'tickets', locale: :en))
        .to eq('Only tickets that are waiting on an open ticket.')
      expect(sentence([flag('waiting', operator: 'not')], subject: 'tickets', locale: :en))
        .to eq('Only tickets that are not waiting on an open ticket.')
      expect(sentence([flag('blocking', operator: 'not')], subject: 'tickets', locale: :en))
        .to eq('Only tickets that are not holding up other tickets.')
      expect(sentence([cond('status', 'open'), flag('waiting'), flag('blocking')], subject: 'tickets', locale: :en))
        .to eq('Only tickets that are open, that are waiting on an open ticket and that are holding up other tickets.')
    end

    it 'keeps an English "not" on its own state' do
      expect(sentence([flag('waiting', operator: 'not'), flag('blocking')], subject: 'tickets', locale: :en))
        .to eq('Only tickets that are not waiting on an open ticket and that are holding up other tickets.')
      expect(sentence([cond('status', %w[open done], operator: 'not'), flag('waiting')], subject: 'tickets', locale: :en))
        .to eq('Only tickets that are neither open nor done and that are waiting on an open ticket.')
    end
  end
end
