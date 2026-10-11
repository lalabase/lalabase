# frozen_string_literal: true

require 'rails_helper'

# Guard: every unbilled state of an account row has a label, in BOTH locales.
#
# Why this exists (the drift it prevents):
# The row partial builds its key from the row's own state:
#
#   t("views.billing_accounts.row.state.#{row.state}")
#
# Dynamic key construction is invisible to i18n-tasks, which only sees literal
# keys, and `raise_on_missing_translations` is commented out in
# config/environments/test.rb. So a fourth unbilled state would ship
# `translation missing: de.views.billing_accounts.row.state.whatever` into the
# cockpit of a paying customer without failing a single example.
#
# Reads the loaded backend rather than `I18n.exists?`: with the en->de fallback
# configured, `I18n.exists?(key, :en)` answers true for a key that exists only in
# German, which is exactly the drift this guard is meant to catch.
RSpec.describe 'Account row state locale keys' do
  scope = %i[views billing_accounts row state].freeze
  locales = %i[de en].freeze

  # nil when absent -- never the fallback value of another locale.
  def stored(locale, *path)
    I18n.backend.send(:translations)[locale]&.dig(*path)
  end

  before { I18n.backend.send(:init_translations) unless I18n.backend.initialized? }

  # The link between the constant and the METHOD, without which everything below guards
  # the wrong thing. The examples further down iterate LABELLED_ROW_STATES, but the page
  # builds its key from Row#state -- a fourth state added to the method and forgotten in
  # the constant would ship "translation missing" with the whole guard still green
  # (measured 2026-08-06: a fourth branch left 47 examples passing).
  #
  # Read off the SOURCE of #state rather than by exercising it: exercising can only reach
  # the situations the spec thinks of, which is the same blind spot one level down.
  #
  # Off the PARSE TREE, not off a regex over the text. The first version of this guard
  # matched `^\s*(?:return\s+)?:(\w+)` and was itself blind to two ordinary Ruby spellings
  # that keep working -- `cond and return :trial` and `if cond then return :trial end` --
  # because both push the symbol behind an expression (measured 2026-08-06: a fourth state
  # in either spelling left this file green). The tree does not care about layout.
  #
  # It collects EVERY symbol literal in the method rather than only returned ones. That
  # over-collects by design: a symbol used for something else here would fail this example
  # loudly, which is the harmless direction. What it still cannot see is a symbol that
  # never appears literally in the method (built by interpolation, or read from a constant
  # defined elsewhere). Whoever writes #state that way owes this guard a second look.
  it 'covers every state the method can actually return' do
    # Parse the source: AST.of cannot inspect methods compiled by Prism (Ruby 3.4+).
    source, line = Subscriptions::AccountSummaries::Row.instance_method(:state).source_location
    find_method = lambda do |node|
      next unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)
      next node if node.type == :DEFN && node.first_lineno == line && node.children.first == :state

      node.children.filter_map { |child| find_method.call(child) }.first
    end
    tree = find_method.call(RubyVM::AbstractSyntaxTree.parse_file(source))
    expect(tree).not_to be_nil
    literals = []
    collect = lambda do |node|
      return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

      literals << node.children.first if %i[SYM LIT].include?(node.type)
      node.children.each { |child| collect.call(child) }
    end
    collect.call(tree)

    mentioned = literals.grep(Symbol).uniq
    expect(mentioned).to match_array(Subscriptions::AccountSummaries::ROW_STATES),
                         'Row#state mentions a state ROW_STATES does not know about (or stopped ' \
                         'mentioning one). Keep the constant in step: everything except AMOUNT_STATE ' \
                         'needs a label in BOTH locales.'
  end

  locales.each do |locale|
    Subscriptions::AccountSummaries::LABELLED_ROW_STATES.each do |state|
      it "has #{locale}.#{scope.join('.')}.#{state}" do
        expect(stored(locale, *scope, state)).to be_present,
                                                 "missing #{locale}.#{scope.join('.')}.#{state} — " \
                                                 'this key is built from ' \
                                                 'Subscriptions::AccountSummaries::LABELLED_ROW_STATES'
      end
    end

    # The other half of the contract: a stale label for a state that no longer
    # exists is dead weight, and the next reader cannot tell it from a live one.
    #
    # `billed` must NOT be here either: that branch prints an amount, and a label
    # for it would be a second, unrendered answer to the same question.
    it "has no #{locale}.#{scope.join('.')} entry outside the state list" do
      stored_keys = (stored(locale, *scope) || {}).keys.map(&:to_s)

      expect(stored_keys)
        .to match_array(Subscriptions::AccountSummaries::LABELLED_ROW_STATES.map(&:to_s))
    end
  end
end
