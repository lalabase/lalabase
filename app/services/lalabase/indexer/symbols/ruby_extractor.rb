# frozen_string_literal: true

require 'parser/current'

module Lalabase
  module Indexer
    module Symbols
      # Extracts code-symbol metadata (class / module / method / constant) from a
      # single Ruby source file via the `parser` gem's AST.
      #
      # Returns an array of hashes shaped for CodeSymbol.insert_all:
      #   { symbol_type:, name:, qualified_name:, file_path:, start_line:,
      #     end_line:, signature:, language:, metadata: }
      #
      # Syntax errors and unparseable files yield an empty array — never raise.
      class RubyExtractor
        include SignatureExtraction

        LANGUAGE = 'ruby'

        def initialize(source:, file_path:)
          @source = source.to_s
          @file_path = file_path.to_s
          @source_lines = @source.lines
          @symbols = []
        end

        def call
          # Suppress parser's verbose warnings to STDERR (Ruby-version-mismatch chatter).
          tree = begin
            Parser::CurrentRuby.parse(@source)
          rescue StandardError
            nil
          end
          return [] if tree.nil?

          walk(tree, [])
          @symbols
        rescue StandardError => e
          # Defensive: ANY parser failure → empty symbols (skip the file). The
          # job-level progress counter still moves forward.
          Rails.logger.debug { "RubyExtractor: skipped #{@file_path} — #{e.class}" } if defined?(Rails)
          []
        end

        private

        def walk(node, scope, prefix: '#')
          return unless node.is_a?(Parser::AST::Node)

          case node.type
          when :class
            handle_class_or_module(node, scope, type: 'class')
          when :module
            handle_class_or_module(node, scope, type: 'module')
          when :sclass
            handle_singleton_class(node, scope)
          when :def
            handle_method(node, scope, prefix: prefix)
          when :defs
            handle_singleton_method(node, scope)
          when :casgn
            handle_constant(node, scope)
          else
            node.children.each { |c| walk(c, scope, prefix: prefix) }
          end
        end

        # def foo(args) ... end
        def handle_method(node, scope, prefix:)
          name = node.children[0].to_s
          @symbols << build_symbol(
            symbol_type: 'method',
            name: name,
            qualified_name: "#{scope.join('::')}#{prefix}#{name}",
            node: node
          )
          # Methods don't contain class/module nesting we care about, but body
          # may contain constant assignments. Walk so we catch them.
          node.children[2..]&.each { |c| walk(c, scope) }
        end

        # def self.foo(args) ... end → class method
        def handle_singleton_method(node, scope)
          name = node.children[1].to_s
          @symbols << build_symbol(
            symbol_type: 'method',
            name: name,
            qualified_name: "#{scope.join('::')}.#{name}",
            node: node
          )
        end

        # class << self ... end → walks body with class-method prefix.
        # Methods defined inside are class methods (Foo.bar), not instance.
        #
        # `class << some_obj` is also valid Ruby (opens the singleton of an
        # instance) — but the methods defined there are NOT callable as
        # `Foo.bar`. Static analysis can't know which instance, so we refuse
        # to lie: only `class << self` produces extractable class methods.
        def handle_singleton_class(node, scope)
          receiver = node.children[0]
          return unless receiver.is_a?(Parser::AST::Node) && receiver.type == :self

          body = node.children[1]
          walk(body, scope, prefix: '.') if body
        end

        def handle_class_or_module(node, scope, type:)
          name = const_name(node.children[0])
          return unless name

          qualified = (scope + [name]).join('::')
          @symbols << build_symbol(
            symbol_type: type,
            name: name,
            qualified_name: qualified,
            node: node
          )
          # Body is the LAST child; nesting position differs for class vs module
          body_index = type == 'class' ? 2 : 1
          body = node.children[body_index]
          # Reset prefix to '#' when entering a new class/module scope: e.g.,
          # `class Foo; class Bar; def baz; end; end; end` → Foo::Bar#baz.
          walk(body, scope + [name], prefix: '#') if body
        end

        # FOO = 'bar'
        def handle_constant(node, scope)
          parent, name = node.children[0..1]
          return unless name # defensive

          qualified_parent = parent ? const_name(parent) : nil
          qualified = [scope.join('::').presence, qualified_parent, name].compact.reject(&:empty?).join('::')
          @symbols << build_symbol(
            symbol_type: 'constant',
            name: name.to_s,
            qualified_name: qualified,
            node: node
          )
        end

        def build_symbol(symbol_type:, name:, qualified_name:, node:)
          start_line = node.loc.line
          end_line = node.loc.respond_to?(:end) && node.loc.end ? node.loc.end.line : start_line
          {
            symbol_type: symbol_type,
            name: name,
            qualified_name: qualified_name,
            file_path: @file_path,
            start_line: start_line,
            end_line: end_line,
            signature: extract_signature(start_line),
            language: LANGUAGE,
            metadata: {}
          }
        end

        # Recursively resolves a nested const node to "Foo::Bar::Baz".
        def const_name(node)
          return nil unless node.is_a?(Parser::AST::Node) && %i[const cbase].include?(node.type)
          return '' if node.type == :cbase

          parent = const_name(node.children[0])
          name   = node.children[1].to_s
          parent.present? ? "#{parent}::#{name}" : name
        end
      end
    end
  end
end
