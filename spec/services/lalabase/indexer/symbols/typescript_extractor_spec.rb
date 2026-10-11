# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Indexer::Symbols::TypescriptExtractor do
  # Hermetic: the compiled grammars live in tmp/ (git-ignored, built per
  # environment). Build them on demand (shared helper) so a clean checkout / CI
  # can run this spec without a prior `bin/setup`.
  before(:all) { TreeSitterGrammarsHelper.ensure_built! }

  def extract(source, file_path: 'src/foo.ts', language: nil, grammar: nil)
    args = { source: source, file_path: file_path }
    args[:language] = language if language
    args[:grammar] = grammar if grammar
    described_class.new(**args).call
  end

  describe 'top-level declarations' do
    it 'extracts a class' do
      symbols = extract('class Foo {}')
      expect(symbols.first).to include(symbol_type: 'class', name: 'Foo',
                                       qualified_name: 'Foo', language: 'typescript')
    end

    it 'extracts an abstract class as a `class` (NOT a distinct type)' do
      symbols = extract('abstract class Shape {}')
      expect(symbols.first).to include(symbol_type: 'class', name: 'Shape')
    end

    it 'extracts an interface' do
      symbols = extract('interface Drawable {}')
      expect(symbols.first).to include(symbol_type: 'interface', name: 'Drawable',
                                       qualified_name: 'Drawable')
    end

    it 'extracts a type alias' do
      symbols = extract('type ID = string | number')
      expect(symbols.first).to include(symbol_type: 'type', name: 'ID')
    end

    it 'extracts an enum' do
      symbols = extract('enum Color { Red, Green, Blue }')
      expect(symbols.first).to include(symbol_type: 'enum', name: 'Color')
    end

    it 'extracts a function declaration' do
      symbols = extract('function compute(a: number): number { return a }')
      expect(symbols.first).to include(symbol_type: 'function', name: 'compute')
    end

    it 'unwraps the export_statement: `export class` still yields the class' do
      symbols = extract('export class Exported {}')
      expect(symbols.map { |s| [s[:symbol_type], s[:name]] }).to eq([%w[class Exported]])
    end

    it 'extracts a non-exported top-level class (export wrapper is optional)' do
      symbols = extract('class NotExported {}')
      expect(symbols.map { |s| s[:name] }).to eq(['NotExported'])
    end
  end

  describe 'export forms (default / re-export)' do
    it 'extracts a default-exported function by its name' do
      symbols = extract('export default function foo() {}')
      expect(symbols.first).to include(symbol_type: 'function', name: 'foo', qualified_name: 'foo')
    end

    it 'skips an anonymous default-exported class (no name to emit)' do
      expect(extract('export default class {}')).to eq([])
    end

    it 'drops an anonymous default-exported class WITH a body — its methods too (known gap, pinned)' do
      # `export default class extends X { connect() {} }` (the Stimulus controller
      # idiom) has no name to emit, and we do NOT descend into an un-emitted class
      # body — so `connect` is lost too. Pinned so a future "name anonymous classes"
      # or "still emit their members" change must consciously update this.
      expect(extract('export default class extends Controller { connect() {} }')).to eq([])
    end

    it 'DOES extract a named class that is default-exported by reference (the workaround)' do
      symbols = extract(<<~TS)
        class Toggle extends Controller {
          connect() {}
        }
        export default Toggle
      TS
      expect(symbols.map { |s| s[:qualified_name] }).to contain_exactly('Toggle', 'Toggle#connect')
    end

    it 'does NOT emit re-exported names as symbols (references, not definitions)' do
      expect(extract("export { x } from './m'")).to eq([])
    end
  end

  describe 'arrow / function vs constant (binding value decides)' do
    it 'classifies an arrow-valued const as a `function`' do
      symbols = extract('const adder = (a, b) => a + b')
      expect(symbols.first).to include(symbol_type: 'function', name: 'adder')
    end

    it 'classifies a function-expression const as a `function`' do
      symbols = extract('const make = function () { return 1 }')
      expect(symbols.first).to include(symbol_type: 'function', name: 'make')
    end

    it 'classifies a generator-function const as a `function` (3rd FUNCTION_VALUE_TYPES entry)' do
      symbols = extract('const g = function* () { yield 1 }')
      expect(symbols.first).to include(symbol_type: 'function', name: 'g')
    end

    it 'classifies a non-function const as a `constant` (the n−1 boundary)' do
      symbols = extract('const PLAIN = 42')
      expect(symbols.first).to include(symbol_type: 'constant', name: 'PLAIN')
    end

    it 'handles several declarators in one statement (`const a = 1, b = () => 2`)' do
      symbols = extract('const a = 1, b = () => 2')
      pairs = symbols.map { |s| [s[:name], s[:symbol_type]] }
      expect(pairs).to contain_exactly(%w[a constant], %w[b function])
    end

    it 'skips an unnameable destructuring binding (no crash, no garbage name)' do
      expect(extract('const { x, y } = point')).to eq([])
    end
  end

  describe 'class members' do
    it 'extracts an instance method as Class#method' do
      symbols = extract(<<~TS)
        class Foo {
          greet(name: string): string { return name }
        }
      TS
      method = symbols.find { |s| s[:symbol_type] == 'method' }
      expect(method).to include(name: 'greet', qualified_name: 'Foo#greet')
    end

    it 'extracts a static method as Class.method (NOT Class#method)' do
      symbols = extract(<<~TS)
        class Foo {
          static make(): Foo { return new Foo() }
        }
      TS
      method = symbols.find { |s| s[:symbol_type] == 'method' }
      expect(method[:qualified_name]).to eq('Foo.make')
    end

    it 'extracts an arrow-valued field as a method (the onClick = () => {} idiom)' do
      symbols = extract(<<~TS)
        class Widget {
          handleClick = () => { return 1 }
        }
      TS
      method = symbols.find { |s| s[:symbol_type] == 'method' }
      expect(method).to include(name: 'handleClick', qualified_name: 'Widget#handleClick')
    end

    it 'does NOT extract a plain data field (count = 0)' do
      symbols = extract(<<~TS)
        class Widget {
          count = 0
          handleClick = () => {}
        }
      TS
      member_names = symbols.reject { |s| s[:symbol_type] == 'class' }.map { |s| s[:name] }
      expect(member_names).to eq(['handleClick'])
    end

    it 'extracts an abstract method signature as a method' do
      symbols = extract(<<~TS)
        abstract class Shape {
          abstract area(): number
        }
      TS
      qns = symbols.map { |s| s[:qualified_name] }
      expect(qns).to contain_exactly('Shape', 'Shape#area')
    end

    it 'extracts get/set accessors as methods (both, same qualified_name)' do
      symbols = extract(<<~TS)
        class C {
          get x() { return 1 }
          set x(v) {}
        }
      TS
      accessors = symbols.select { |s| s[:symbol_type] == 'method' }
      expect(accessors.map { |s| s[:qualified_name] }).to eq(%w[C#x C#x])
    end

    it 'extracts a generator method' do
      symbols = extract(<<~TS)
        class C {
          *gen() {}
        }
      TS
      expect(symbols.find { |s| s[:symbol_type] == 'method' })
        .to include(name: 'gen', qualified_name: 'C#gen')
    end

    it 'emits both a static and an instance member of the same name' do
      symbols = extract(<<~TS)
        class Foo {
          x() {}
          static x() {}
        }
      TS
      qns = symbols.select { |s| s[:symbol_type] == 'method' }.map { |s| s[:qualified_name] }
      expect(qns).to contain_exactly('Foo#x', 'Foo.x')
    end

    it 'extracts a static arrow field as a static method (Foo.field, not Foo#field)' do
      # Combines two decisions at once: static? (→ '.') AND function_valued? (a
      # function-valued field is a method). A regression in either flips the result.
      symbols = extract(<<~TS)
        class Foo {
          static onClick = () => {}
        }
      TS
      method = symbols.find { |s| s[:symbol_type] == 'method' }
      expect(method[:qualified_name]).to eq('Foo.onClick')
    end

    it 'skips members with computed or quoted names (the NAME_NODE_TYPES whitelist, negative side)' do
      symbols = extract(<<~TS)
        class C {
          ['computed']() {}
          "quoted"() {}
          normal() {}
        }
      TS
      methods = symbols.select { |s| s[:symbol_type] == 'method' }
      expect(methods.map { |s| s[:qualified_name] }).to eq(['C#normal'])
    end
  end

  describe 'declarations are single symbols — no member descent' do
    it 'does NOT emit interface members as separate symbols' do
      symbols = extract(<<~TS)
        interface Drawable {
          draw(): void
          color: string
        }
      TS
      expect(symbols.map { |s| s[:name] }).to eq(['Drawable'])
    end

    it 'does NOT emit enum values as separate symbols' do
      symbols = extract('enum Color { Red, Green, Blue }')
      expect(symbols.map { |s| s[:name] }).to eq(['Color'])
    end
  end

  describe 'bodies are not descended (no local / closure leak)' do
    # The recursion only enters containers (program/export/blocks) and class /
    # namespace bodies — function and method bodies are leaves. If walk ever
    # started descending into them, local helpers would pollute the index.
    it 'does NOT extract declarations inside a function body' do
      symbols = extract(<<~TS)
        function outer() {
          const inside = 1
          class LocalOnly {}
          function innerFn() {}
        }
      TS
      expect(symbols.map { |s| [s[:symbol_type], s[:qualified_name]] }).to eq([%w[function outer]])
    end

    it 'does NOT extract declarations inside a method body' do
      symbols = extract(<<~TS)
        class C {
          build() {
            class Local {}
            const helper = () => {}
          }
        }
      TS
      pairs = symbols.map { |s| [s[:symbol_type], s[:qualified_name]] }
      expect(pairs).to contain_exactly(%w[class C], %w[method C#build])
    end
  end

  describe 'namespace scoping' do
    it 'emits the namespace as a `module` and qualifies nested declarations' do
      symbols = extract(<<~TS)
        namespace Geometry {
          export class Point {}
          export function dist(): number { return 0 }
        }
      TS
      triples = symbols.map { |s| [s[:symbol_type], s[:name], s[:qualified_name]] }
      expect(triples).to contain_exactly(
        %w[module Geometry Geometry],
        ['class', 'Point', 'Geometry.Point'],
        ['function', 'dist', 'Geometry.dist']
      )
    end

    it 'threads scope through nested namespaces (A.B.Deep)' do
      symbols = extract(<<~TS)
        namespace A {
          namespace B {
            export class Deep {}
          }
        }
      TS
      pairs = symbols.map { |s| [s[:symbol_type], s[:qualified_name]] }
      expect(pairs).to contain_exactly(%w[module A], %w[module A.B], %w[class A.B.Deep])
    end

    it 'handles the older `module Foo {}` namespace synonym' do
      symbols = extract(<<~TS)
        module Legacy {
          export function helper() {}
        }
      TS
      pairs = symbols.map { |s| [s[:symbol_type], s[:qualified_name]] }
      expect(pairs).to contain_exactly(%w[module Legacy], %w[function Legacy.helper])
    end
  end

  describe 'line ranges' do
    it 'records 1-based start_line and end_line' do
      source = <<~TS
        class Foo {
          bar() {
            return 1
          }
        }
      TS
      symbols = extract(source)
      klass = symbols.find { |s| s[:symbol_type] == 'class' }
      method = symbols.find { |s| s[:symbol_type] == 'method' }
      expect(klass).to include(start_line: 1, end_line: 5)
      expect(method).to include(start_line: 2, end_line: 4)
    end
  end

  describe 'signature extraction' do
    it 'captures the declaration line with its keyword and signature' do
      symbols = extract('export interface Drawable { draw(): void }')
      expect(symbols.first[:signature]).to include('interface Drawable')
    end

    it 'caps signature length at MAX_SIGNATURE_LENGTH' do
      args = (0..200).map { |i| "arg#{i}: number" }.join(', ')
      symbols = extract("function big(#{args}) {}")
      expect(symbols.first[:signature].length).to be <= described_class::MAX_SIGNATURE_LENGTH
      expect(symbols.first[:signature]).to start_with('function big(') # not empty / garbage
    end

    it 'caps the signature at SIGNATURE_LINE_LIMIT lines but keeps the full line range' do
      symbols = extract(<<~TS)
        function big(
          a: number,
          b: number,
          c: number
        ): number { return a }
      TS
      fn = symbols.first
      expect(fn).to include(start_line: 1, end_line: 5) # full span, not capped at 3
      expect(fn[:signature]).to include('function big(').and include('a: number')
      expect(fn[:signature]).not_to include('c: number') # 4th line dropped by the 3-line cap
    end
  end

  describe 'error tolerance (defensive — never raises)' do
    it 'returns [] for malformed TypeScript' do
      expect(extract('const x = (((')).to eq([])
    end

    it 'drops the WHOLE file on a syntax error — even its valid declarations (all-or-nothing)' do
      # A half-edited file: `Valid` parses fine, but the broken const makes
      # root.has_error? true. We refuse a partial result rather than indexing
      # `Valid` and silently dropping the rest. (The pure-garbage case above can't
      # tell "all-or-nothing" apart from "extract the valid parts" — this can.)
      expect(extract("class Valid {}\nconst broken = (((")).to eq([])
    end

    it 'returns [] for binary garbage' do
      expect(extract("\xFF\xFE\xFD".b)).to eq([])
    end

    it 'returns [] for empty source' do
      expect(extract('')).to eq([])
    end
  end

  describe 'unicode identifiers' do
    it 'preserves UTF-8 names via byte-accurate slicing' do
      symbols = extract(<<~TS)
        class MitUmlaut {
          grüßen() {}
        }
      TS
      method = symbols.find { |s| s[:symbol_type] == 'method' }
      expect(method).to include(name: 'grüßen', qualified_name: 'MitUmlaut#grüßen')
    end
  end

  describe 'metadata field shape' do
    it 'passes the source file_path through unchanged' do
      symbols = extract('class Foo {}', file_path: 'app/frontend/foo.ts')
      expect(symbols.first[:file_path]).to eq('app/frontend/foo.ts')
    end

    it 'tags every symbol with language=typescript by default' do
      symbols = extract(<<~TS)
        class Foo { bar() {} }
        const X = 1
      TS
      expect(symbols.map { |s| s[:language] }).to all(eq('typescript'))
    end

    it 'honors a custom language: on EVERY emit path (the .js → javascript seam)' do
      # Multi-symbol on purpose: a top-level decl, a class member, a binding and a
      # namespaced decl all flow through emit — a regression that hardcoded the
      # language in any single path would survive a one-symbol test, not this one.
      symbols = extract(<<~TS, language: 'javascript')
        export class Service { run() {} }
        const X = 1
        namespace N { export function f() {} }
      TS
      expect(symbols.size).to be >= 5 # class, method, const, module, nested fn
      expect(symbols.map { |s| s[:language] }).to all(eq('javascript'))
    end

    it 'always sets an (empty) metadata hash' do
      symbols = extract('class Foo {}')
      expect(symbols.first[:metadata]).to eq({})
    end
  end

  describe 'the complete emitted hash (emit pipeline — all fields together)' do
    it 'fills every field correctly for a multi-line method' do
      symbols = extract(<<~TS)
        class Foo {
          bar(x) {
            return x
          }
        }
      TS
      method = symbols.find { |s| s[:symbol_type] == 'method' }
      expect(method).to include(
        symbol_type: 'method',
        name: 'bar',
        qualified_name: 'Foo#bar', # ≠ name — pins name/qualified_name aren't swapped
        file_path: 'src/foo.ts',
        start_line: 2,
        end_line: 4, # spans 3 lines — pins start_line/end_line aren't swapped/equal
        language: 'typescript',
        metadata: {}
      )
      expect(method[:signature]).to include('bar(x)')
    end
  end

  describe 'realistic mixed file (the walk end-to-end — nothing dropped, duplicated or leaked)' do
    it 'emits exactly the expected symbol set' do
      symbols = extract(<<~TS)
        export class Service {
          private count = 0
          static build(): Service { return new Service() }
          run(): void {}
          onTick = () => {}
        }

        export interface Config { url: string }
        export type Id = string
        export enum Level { Low, High }
        export function helper(): number { return 1 }
        export const factory = () => new Service()
        const MAX = 100

        namespace Util {
          export function noop(): void {}
        }
      TS
      pairs = symbols.map { |s| [s[:symbol_type], s[:qualified_name]] }
      expect(pairs).to contain_exactly(
        %w[class Service],
        %w[method Service.build],  # static → '.'
        %w[method Service#run],    # instance → '#'
        %w[method Service#onTick], # arrow field → method
        # `private count = 0` is a data field → intentionally NOT present
        %w[interface Config],
        %w[type Id],
        %w[enum Level],
        %w[function helper],
        %w[function factory], # arrow const → function
        %w[constant MAX],
        %w[module Util],
        %w[function Util.noop] # nested in the namespace
      )
    end
  end

  describe 'tsx grammar — JSX via the grammar: knob' do
    let(:jsx_component) do
      <<~TSX
        export class Button extends Component {
          handleClick(e) { return e }
          render() { return <button onClick={this.handleClick}>Hi</button> }
        }
        export const Card = (props) => <div className="card">{props.children}</div>
      TSX
    end

    it 'parses JSX and extracts its declarations with grammar: "tsx"' do
      symbols = extract(jsx_component, file_path: 'src/Button.tsx', grammar: 'tsx')
      pairs = symbols.map { |s| [s[:symbol_type], s[:qualified_name]] }
      expect(pairs).to contain_exactly(
        %w[class Button], %w[method Button#handleClick], %w[method Button#render], %w[function Card]
      )
    end

    it 'returns [] for the SAME JSX under the default typescript grammar (the knob matters)' do
      # The plain typescript grammar errors on JSX → has_error? → all-or-nothing.
      expect(extract(jsx_component, file_path: 'src/Button.tsx')).to eq([])
    end

    it 'extracts plain (JSX-free) declarations under the tsx grammar too (clean superset)' do
      # A .tsx file without JSX must still yield full symbols — tsx is a superset,
      # not a JSX-only dialect. Guards against routing non-JSX .tsx away from tsx.
      symbols = extract('export class Plain { run() {} }', file_path: 'src/Plain.tsx', grammar: 'tsx')
      expect(symbols.map { |s| s[:qualified_name] }).to contain_exactly('Plain', 'Plain#run')
    end
  end

  describe 'constants locked as contract' do
    it { expect(described_class::LANGUAGE).to eq('typescript') }
    it { expect(described_class::DEFAULT_GRAMMAR).to eq('typescript') }
    it { expect(described_class::MAX_SIGNATURE_LENGTH).to eq(500) }
    it { expect(described_class::SIGNATURE_LINE_LIMIT).to eq(3) }
  end

  describe 'positive whitelist iteration over emitted symbol_types' do
    # Every type the TS extractor can emit must appear from one representative
    # snippet — and must be a value CodeSymbol accepts.
    let(:symbols) do
      extract(<<~TS)
        export class C { m() {} }
        export interface I {}
        export type T = string
        export enum E { A }
        export function f() {}
        export const g = () => {}
        const K = 1
        namespace N {}
      TS
    end

    %w[class module method function constant interface type enum].each do |type|
      it "emits at least one #{type.inspect} symbol" do
        expect(symbols.map { |s| s[:symbol_type] }).to include(type)
      end
    end

    it 'only emits symbol_types CodeSymbol whitelists' do
      expect(symbols.map { |s| s[:symbol_type] }.uniq).to all(be_in(CodeSymbol::SYMBOL_TYPES))
    end
  end
end
