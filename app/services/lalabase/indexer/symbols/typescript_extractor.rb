# frozen_string_literal: true

require 'tree_sitter'

module Lalabase
  module Indexer
    module Symbols
      # Extracts code-symbol metadata from a single TypeScript / TSX source file
      # via tree-sitter. The Walker decides which files reach it (M10 #39) and
      # sets two ORTHOGONAL knobs:
      #   language: the tag stored on each symbol — 'typescript' (.ts/.tsx) or
      #             'javascript' (.js/.jsx/.mjs/.cjs).
      #   grammar:  which compiled grammar parses the bytes — 'typescript' for
      #             non-JSX (.ts/.js), 'tsx' for JSX (.tsx/.jsx). The plain
      #             typescript grammar ERRORS on JSX, hence the split. Both
      #             grammars emit the SAME declaration nodes, so the walk below is
      #             grammar-agnostic — only JSX syntax differs, and we never
      #             descend into it.
      #
      # Returns the SAME hash shape as RubyExtractor, ready for
      # CodeSymbol.insert_all:
      #   { symbol_type:, name:, qualified_name:, file_path:, start_line:,
      #     end_line:, signature:, language:, metadata: }
      #
      # Parse errors / unparseable input yield [] — never raises.
      #
      # tree-sitter SAFETY: the Parser, Tree and every Node stay LOCAL to #call.
      # The gem's C binding can segfault the worker if a Node outlives its Tree,
      # so we never store one in an ivar or return one — only plain Hashes leave
      # here. (The Language object IS safe to share; TreeSitterGrammar memoises it.)
      class TypescriptExtractor
        include SignatureExtraction

        LANGUAGE = 'typescript'
        DEFAULT_GRAMMAR = 'typescript' # 'tsx' is the only other (for .tsx/.jsx)

        # A binding whose value is one of these is a function (→ symbol_type
        # 'function'), not a constant: `const f = () => {}` / `const g = function(){}`.
        # These are the *expression* forms tree-sitter puts as the declarator's
        # value; the bare `function` keyword token is never a declarator's direct
        # child (it lives inside `function_expression`), so it is not listed here.
        FUNCTION_VALUE_TYPES = %i[arrow_function function_expression generator_function].freeze

        # Node types we accept as a symbol name. Anything else a `name` field can
        # hold — object_pattern from `const {a} = x`, array_pattern — is
        # unnameable, so we skip it rather than slice it into a garbage name.
        NAME_NODE_TYPES = %i[identifier property_identifier type_identifier].freeze

        def initialize(source:, file_path:, language: LANGUAGE, grammar: DEFAULT_GRAMMAR)
          @source = source.to_s
          @file_path = file_path.to_s
          @language = language.to_s
          @grammar = grammar.to_s
          @source_lines = @source.lines
          @symbols = []
        end

        def call
          parser = TreeSitter::Parser.new
          parser.language = TreeSitterGrammar.language(@grammar)
          tree = parser.parse_string(nil, @source)
          return [] if tree.nil?

          root = tree.root_node
          # tree-sitter recovers from syntax errors by inserting ERROR nodes and
          # parsing on — which can yield garbage names from misparsed regions.
          # Like RubyExtractor (parse → nil on SyntaxError) we refuse a partial
          # result: one bad file drops to [] rather than poisoning the index.
          return [] if root.has_error?

          walk(root, [])
          @symbols
        rescue StandardError => e
          # ANY failure (parse, the C binding, or a missing grammar) → skip this
          # file. The grammar being built is an infra guarantee (bin/setup + the
          # deploy hook, #41); the indexer's progress counter still moves on.
          Rails.logger.debug { "TypescriptExtractor: skipped #{@file_path} — #{e.class}" } if defined?(Rails)
          []
        end

        private

        # scope = enclosing namespace/class names (e.g. ["Geometry", "Point"]).
        # We recurse only THROUGH container nodes (program/export/blocks) and into
        # class/namespace bodies — never into function or method bodies, so local
        # closures don't leak into the index.
        def walk(node, scope)
          case node.type
          when :class_declaration, :abstract_class_declaration
            handle_class(node, scope)
          when :interface_declaration  then emit_declaration(node, scope, 'interface')
          when :type_alias_declaration then emit_declaration(node, scope, 'type')
          when :enum_declaration       then emit_declaration(node, scope, 'enum')
          when :function_declaration   then emit_declaration(node, scope, 'function')
          when :internal_module, :module then handle_namespace(node, scope)
          when :lexical_declaration, :variable_declaration
            handle_bindings(node, scope)
          when :program, :export_statement, :statement_block, :expression_statement
            # Pass-through containers: top-level decls are wrapped in
            # export_statement; namespace bodies are statement_blocks; and the TS
            # grammar wraps a `namespace X {}` in an expression_statement. Walking
            # into these reaches the declarations; non-declaration children (a
            # function call, an IIFE) simply have no matching case and stop.
            node.each { |child| walk(child, scope) }
          end
        end

        # class Foo { ... } / abstract class Foo { ... } — emitted as `class`,
        # then its body is walked for member methods.
        def handle_class(node, scope)
          name = name_of(node)
          return unless name

          emit(symbol_type: 'class', name: name, qualified_name: qualify(scope, name), node: node)

          body = find_child(node) { |child| child.type == :class_body }
          inner = scope + [name]
          body&.each { |member| handle_member(member, inner) }
        end

        # namespace Foo { ... } — or the older `module Foo { ... }` synonym; both
        # parse with an identifier `name` field + a statement_block body. Ruby's
        # nearest analog is a module: it scopes its children and is walked for
        # nested declarations. (A string-named ambient `module "x" {}` has no
        # plain-identifier name, so name_of returns nil and it is skipped.)
        def handle_namespace(node, scope)
          name = name_of(node)
          return unless name

          emit(symbol_type: 'module', name: name, qualified_name: qualify(scope, name), node: node)
          inner = scope + [name]
          node.each { |child| walk(child, inner) }
        end

        # interface / type / enum / function — one symbol, no body descent.
        # interface members and enum values are NOT separate symbols: the
        # declaration line is the symbol, and Ruby has no analog to descend into.
        def emit_declaration(node, scope, symbol_type)
          name = name_of(node)
          return unless name

          emit(symbol_type: symbol_type, name: name, qualified_name: qualify(scope, name), node: node)
        end

        # const / let / var — one statement can bind several names
        # (`const a = 1, b = 2`). Arrow/function values become `function` symbols;
        # everything else `constant`, matching RubyExtractor treating top-level
        # assignments as constants.
        def handle_bindings(node, scope)
          node.each do |child|
            next unless child.type == :variable_declarator

            name = name_of(child)
            next unless name

            symbol_type = function_valued?(child) ? 'function' : 'constant'
            emit(symbol_type: symbol_type, name: name, qualified_name: qualify(scope, name), node: child)
          end
        end

        # A class member. We extract methods (incl. abstract signatures) and
        # arrow-valued fields — the `onClick = () => {}` idiom is semantically a
        # method. Plain data fields (`count = 0`) are NOT symbols, matching
        # RubyExtractor's skip of ivars/attrs.
        def handle_member(node, class_scope)
          type = node.type
          method_like = type == :method_definition ||
                        type == :abstract_method_signature ||
                        (type == :public_field_definition && function_valued?(node))
          return unless method_like

          name = name_of(node)
          return unless name

          # Mirror RubyExtractor: `#` for instance members, `.` for static ones.
          prefix = static?(node) ? '.' : '#'
          emit(symbol_type: 'method', name: name,
               qualified_name: "#{class_scope.join('.')}#{prefix}#{name}", node: node)
        end

        # Nested / namespaced names join with TS-native '.' ("Geometry.Point"),
        # not Ruby's '::'. (Class members use '#' / '.' instead — see handle_member.)
        def qualify(scope, name)
          (scope + [name]).join('.')
        end

        def emit(symbol_type:, name:, qualified_name:, node:)
          start_line = node.start_point.row + 1 # tree-sitter rows are 0-based
          @symbols << {
            symbol_type: symbol_type,
            name: name,
            qualified_name: qualified_name,
            file_path: @file_path,
            start_line: start_line,
            end_line: node.end_point.row + 1,
            signature: extract_signature(start_line),
            language: @language,
            metadata: {}
          }
        end

        # The name via the grammar's `name` field — nil if absent or not a plain
        # identifier (destructuring patterns, computed names) we'd only mangle.
        def name_of(node)
          name_node = node.child_by_field_name('name')
          return nil unless name_node && NAME_NODE_TYPES.include?(name_node.type)

          slice(name_node)
        end

        # tree-sitter works in bytes; there is no Node#text in this gem. Slicing
        # the original source by byte range is the documented way to read a node.
        def slice(node)
          @source.byteslice(node.start_byte...node.end_byte)
        end

        # First direct child for which the block is truthy, or nil. We iterate
        # fully rather than returning early: a non-local exit out of the gem's
        # C-backed iterator is a needless risk, and these child lists are tiny.
        def find_child(node)
          match = nil
          node.each { |child| match = child if match.nil? && yield(child) }
          match
        end

        def any_child?(node, &predicate)
          !find_child(node, &predicate).nil?
        end

        # Carries a `static` modifier token (static method / field)?
        def static?(node)
          any_child?(node) { |child| child.type == :static }
        end

        # Direct child is a function value (arrow / function expression)?
        def function_valued?(node)
          any_child?(node) { |child| FUNCTION_VALUE_TYPES.include?(child.type) }
        end
      end
    end
  end
end
