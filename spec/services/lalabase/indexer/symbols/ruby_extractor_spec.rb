# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Indexer::Symbols::RubyExtractor do
  def extract(source, file_path: 'app/services/foo.rb')
    described_class.new(source: source, file_path: file_path).call
  end

  describe 'class & module' do
    it 'extracts a top-level class' do
      symbols = extract(<<~RB)
        class Foo
        end
      RB
      expect(symbols.size).to eq(1)
      expect(symbols.first).to include(symbol_type: 'class', name: 'Foo',
                                       qualified_name: 'Foo', language: 'ruby')
    end

    it 'extracts a top-level module' do
      symbols = extract('module Bar; end')
      expect(symbols.first).to include(symbol_type: 'module', name: 'Bar', qualified_name: 'Bar')
    end

    it 'nests qualified_name under enclosing module/class scope' do
      symbols = extract(<<~RB)
        module Outer
          class Inner
          end
        end
      RB
      qns = symbols.map { |s| s[:qualified_name] }
      expect(qns).to eq(%w[Outer Outer::Inner])
    end

    it 'supports compact constant paths in class definitions (class A::B)' do
      symbols = extract('class A::B; end')
      expect(symbols.first[:qualified_name]).to eq('A::B')
    end
  end

  describe 'methods' do
    it 'extracts instance methods as ClassName#method_name' do
      symbols = extract(<<~RB)
        class Foo
          def bar(x)
          end
        end
      RB
      method = symbols.find { |s| s[:symbol_type] == 'method' }
      expect(method[:qualified_name]).to eq('Foo#bar')
      expect(method[:name]).to eq('bar')
    end

    it 'extracts class methods as ClassName.method_name' do
      symbols = extract(<<~RB)
        class Foo
          def self.baz
          end
        end
      RB
      method = symbols.find { |s| s[:symbol_type] == 'method' }
      expect(method[:qualified_name]).to eq('Foo.baz')
    end

    it 'works for methods inside a deeply nested module/class' do
      symbols = extract(<<~RB)
        module App
          module Services
            class Foo
              def call; end
            end
          end
        end
      RB
      method = symbols.find { |s| s[:symbol_type] == 'method' }
      expect(method[:qualified_name]).to eq('App::Services::Foo#call')
    end
  end

  describe 'constants' do
    it 'extracts top-level constants' do
      symbols = extract('FOO = 42')
      expect(symbols.first).to include(symbol_type: 'constant', name: 'FOO', qualified_name: 'FOO')
    end

    it 'extracts constants inside a class' do
      symbols = extract(<<~RB)
        class Foo
          BAR = 'baz'
        end
      RB
      const = symbols.find { |s| s[:symbol_type] == 'constant' }
      expect(const[:qualified_name]).to eq('Foo::BAR')
    end
  end

  describe 'signature extraction' do
    it 'captures the def line with arguments' do
      symbols = extract(<<~RB)
        class Foo
          def call(name, age: 18)
            return name
          end
        end
      RB
      method = symbols.find { |s| s[:symbol_type] == 'method' }
      expect(method[:signature]).to include('def call(name, age: 18)')
    end

    it 'caps signature length at MAX_SIGNATURE_LENGTH' do
      huge_args = 'arg' + ('x' * 1000).chars.each_slice(20).map.with_index { |c, i| ", arg_#{i}_#{c.first}" }.join
      symbols = extract("class Foo\n  def big(#{huge_args})\n  end\nend")
      method = symbols.find { |s| s[:symbol_type] == 'method' }
      expect(method[:signature].length).to be <= described_class::MAX_SIGNATURE_LENGTH
    end
  end

  describe 'line ranges' do
    it 'records start_line and end_line correctly' do
      source = <<~RB
        class Foo
          def bar
            1 + 1
          end
        end
      RB
      symbols = extract(source)
      klass = symbols.find { |s| s[:symbol_type] == 'class' }
      method = symbols.find { |s| s[:symbol_type] == 'method' }
      expect(klass[:start_line]).to eq(1)
      expect(klass[:end_line]).to eq(5)
      expect(method[:start_line]).to eq(2)
      expect(method[:end_line]).to eq(4)
    end
  end

  describe 'error tolerance (defensive)' do
    it 'returns an empty array for malformed Ruby (no crash)' do
      expect(extract('def foo(((')).to eq([])
    end

    it 'returns an empty array for binary garbage' do
      expect(extract("\xFF\xFE\xFD".b)).to eq([])
    end

    it 'returns an empty array for empty source' do
      expect(extract('')).to eq([])
    end
  end

  describe 'constants locked as contract' do
    it { expect(described_class::LANGUAGE).to eq('ruby') }
    it { expect(described_class::MAX_SIGNATURE_LENGTH).to eq(500) }
    it { expect(described_class::SIGNATURE_LINE_LIMIT).to eq(3) }
  end

  describe 'metadata field shape' do
    it 'always includes the file_path of the source' do
      symbols = extract('class Foo; end', file_path: 'lib/baz.rb')
      expect(symbols.first[:file_path]).to eq('lib/baz.rb')
    end

    it 'tags every symbol with language=ruby' do
      symbols = extract(<<~RB)
        class Foo
          def bar; end
          BAZ = 1
        end
      RB
      expect(symbols.map { |s| s[:language] }).to all(eq('ruby'))
    end
  end

  describe 'singleton class (class << self) — class methods' do
    # Rails idiom — must be classified as class methods (Foo.bar), not instance.
    it 'classifies methods inside `class << self` as class methods (Foo.bar)' do
      symbols = extract(<<~RB)
        class Foo
          class << self
            def all
            end

            def find(id)
            end
          end
        end
      RB
      methods = symbols.select { |s| s[:symbol_type] == 'method' }
      qns = methods.map { |s| s[:qualified_name] }.sort
      expect(qns).to eq(%w[Foo.all Foo.find])
    end

    it 'still allows regular instance methods alongside the singleton-class block' do
      symbols = extract(<<~RB)
        class Foo
          def instance_method; end

          class << self
            def class_method; end
          end
        end
      RB
      qns = symbols.select { |s| s[:symbol_type] == 'method' }.map { |s| s[:qualified_name] }.sort
      expect(qns).to eq(%w[Foo#instance_method Foo.class_method])
    end
  end

  describe 'inheritance — superclass is NOT extracted as a separate symbol' do
    # Documents the decision: a `class Foo < Bar` defines Foo only; Bar is a
    # reference. If we ever add inheritance-metadata, this test breaks and
    # forces a deliberate update.
    it 'returns only the subclass, not the superclass const reference' do
      symbols = extract('class Child < Parent; end')
      classes = symbols.select { |s| s[:symbol_type] == 'class' }
      expect(classes.map { |s| s[:name] }).to eq(['Child'])
    end
  end

  describe 'positive whitelist iteration over symbol_type' do
    %w[class module method constant].each do |type|
      it "emits at least one #{type.inspect} symbol from a representative snippet" do
        symbols = extract(<<~RB)
          MODULE_CONST = 1
          module M
            CLASS_CONST = 2
            class C
              def m; end
            end
          end
        RB
        expect(symbols.map { |s| s[:symbol_type] }).to include(type)
      end
    end
  end

  describe 'method redefined in the same class (Ruby allows it)' do
    it 'emits both definitions — call-site decides which wins, indexer records history' do
      symbols = extract(<<~RB)
        class Foo
          def bar
            1
          end

          def bar
            2
          end
        end
      RB
      bars = symbols.select { |s| s[:name] == 'bar' }
      expect(bars.size).to eq(2)
    end
  end

  describe 'class << instance_var (instance-singleton, NOT class methods)' do
    # Subtle: `class << some_obj` opens the singleton of an INSTANCE, not the
    # class. Methods defined there are not callable as `Foo.bar` — they only
    # exist on that one instance. Our extractor must not lie about that.
    it 'does NOT extract methods defined on an instance-singleton as Foo.bar' do
      symbols = extract(<<~RB)
        class Foo
          obj = Object.new
          class << obj
            def special; end
          end
        end
      RB
      methods = symbols.select { |s| s[:symbol_type] == 'method' }
      # The special method is genuinely opaque to static analysis — don't claim
      # it's Foo.special. Either drop it or mark it specially. We drop.
      expect(methods.map { |m| m[:qualified_name] }).not_to include('Foo.special')
    end

    it 'still extracts the enclosing class itself' do
      symbols = extract(<<~RB)
        class Foo
          class << obj
            def special; end
          end
        end
      RB
      classes = symbols.select { |s| s[:symbol_type] == 'class' }
      expect(classes.map { |s| s[:name] }).to eq(['Foo'])
    end
  end

  describe 'unicode identifiers (Ruby allows them)' do
    it 'preserves UTF-8 method names' do
      symbols = extract(<<~RB)
        class MitUmlaut
          def grußen
          end
        end
      RB
      method = symbols.find { |s| s[:symbol_type] == 'method' }
      expect(method[:name]).to eq('grußen')
    end
  end
end
