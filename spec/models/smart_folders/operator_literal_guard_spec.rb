# frozen_string_literal: true

require 'rails_helper'
require 'ripper'

# Keeps SmartFolders::Operators the single source of truth for the smart-folder rule operator
# vocabulary. Without this guard the module is a one-time cleanup: the next filter class written
# with `when 'equals'` passes review unnoticed, and the module quietly becomes a list that only
# claims to own the vocabulary.
#
# The values are persisted verbatim in smart_folder_rules.operator and interpolated into i18n keys
# ("smart_folders.operators.#{op}"), so a stray literal is not merely a style issue — it is a
# second, unowned declaration of a value that stored rules depend on.
#
# Source-text contract, deliberately separate from the behavioural specs. Lexed with Ripper rather
# than grepped: several operator names are also SQL keywords ("IS NULL", "BETWEEN ? AND ?") and
# appear in prose comments, and a regex cannot tell those apart from a real literal.
RSpec.describe 'Smart-folder operator literal guard' do
  # Locals (not constants) so they stay scoped to this guard and don't trip
  # Lint/ConstantDefinitionInBlock.
  module_path = 'app/models/smart_folders/operators.rb'

  # The forbidden vocabulary is READ FROM the module, so the guard can never drift from it.
  operator_values = SmartFolders::Operators.constants
                                           .map { |c| SmartFolders::Operators.const_get(c) }
                                           .grep(String)

  # Every place the vocabulary may legitimately appear. Directory globs, not a file list, so a
  # newly added filter or service is covered the moment it lands.
  ruby_files = Dir[
    Rails.root.join('app/models/smart_folder*.rb').to_s,
    Rails.root.join('app/models/smart_folders/**/*.rb').to_s,
    Rails.root.join('app/services/smart_folder*.rb').to_s,
    Rails.root.join('app/services/ad_hoc_to_smart_folder_service.rb').to_s,
    Rails.root.join('app/services/projects/default_smart_folder_service.rb').to_s,
    Rails.root.join('app/helpers/smart_folder_helper.rb').to_s,
    Rails.root.join('app/components/dashboard/smart_folder*.rb').to_s,
    Rails.root.join('app/controllers/organisations/smart_folders_controller.rb').to_s,
    Rails.root.join('app/policies/smart_folder_policy.rb').to_s
  ].uniq.reject { |f| f.end_with?('smart_folders/operators.rb') }

  erb_files = Dir[
    Rails.root.join('app/views/organisations/smart_folder*/**/*.erb').to_s,
    Rails.root.join('app/components/dashboard/smart_folder*.erb').to_s
  ].uniq

  js_files = Dir[Rails.root.join('app/javascript/**/*.js').to_s]

  # Ruby code tokens only: :on_comment and the HTML around ERB tags never reach this.
  string_tokens = lambda do |source|
    Ripper.lex(source).filter_map { |(pos, type, tok, _)| [pos[0], tok] if type == :on_tstring_content }
  rescue StandardError
    []
  end

  const_tokens = lambda do |source|
    Ripper.lex(source).filter_map { |(_, type, tok, _)| tok if type == :on_const }
  rescue StandardError
    []
  end

  # Only the Ruby inside <% %> / <%= %>; the surrounding markup is not code and must not be lexed.
  erb_code = ->(source) { source.scan(/<%=?-?(.*?)-?%>/m).flatten.join("\n") }

  it 'has a non-empty scope (a rename must not silently make this guard vacuous)' do
    expect(Rails.root.join(module_path)).to exist
    expect(operator_values.size).to be >= 20
    expect(ruby_files.size).to be >= 15
    expect(erb_files).not_to be_empty
  end

  describe 'no naked operator literals outside the module' do
    ruby_files.each do |path|
      rel = Pathname.new(path).relative_path_from(Rails.root).to_s

      it "#{rel} references operators through SmartFolders::Operators" do
        offenders = string_tokens.call(File.read(path))
                                 .select { |(_, tok)| operator_values.include?(tok) }
                                 .map { |(line, tok)| "#{rel}:#{line} → '#{tok}'" }

        expect(offenders).to be_empty, lambda {
          'Naked operator literal(s) found. Include SmartFolders::Operators and use the constant ' \
            "(a group like RELATIVE_DATE / MULTI_TAG if the operators belong together):\n  " +
            offenders.join("\n  ")
        }
      end
    end

    erb_files.each do |path|
      rel = Pathname.new(path).relative_path_from(Rails.root).to_s

      it "#{rel} references operators through SmartFolders::Operators" do
        offenders = string_tokens.call(erb_code.call(File.read(path)))
                                 .select { |(_, tok)| operator_values.include?(tok) }
                                 .map { |(_, tok)| "'#{tok}'" }

        expect(offenders).to be_empty, lambda {
          "Naked operator literal(s) in #{rel}: #{offenders.uniq.join(', ')}. Views have no " \
            'include context — use the qualified form, e.g. SmartFolders::Operators::BETWEEN.'
        }
      end
    end
  end

  # Catches the regression this guard was written after: ALL and PRESENCE_ALIASES shipped with no
  # consumer, and a comment described a filtering effect that ALL never had.
  it 'defines no constant without a consumer' do
    used = (ruby_files.flat_map { |f| const_tokens.call(File.read(f)) } +
            erb_files.flat_map { |f| const_tokens.call(erb_code.call(File.read(f))) }).uniq

    unused = SmartFolders::Operators.constants.map(&:to_s) - used

    expect(unused).to be_empty, lambda {
      "Unused constant(s) in #{module_path}: #{unused.join(', ')}. A constant nothing reads is " \
        'not a source of truth — wire it up or delete it.'
    }
  end

  # The Stimulus rule builder keeps hand-maintained copies of four operator groups; Ruby constants
  # do not cross that boundary. Deliberate duplication is allowed, but it has to stay marked, and
  # the count is pinned so a new copy forces a decision instead of landing silently.
  #
  # Four is already past the project's "unify at the third case" trigger — the number is recorded
  # here as known debt, not as an endorsement. The fix is to render the vocabulary into a data-*
  # attribute from Ruby; until then this at least stops the drift from growing unnoticed.
  describe 'the JavaScript mirrors stay marked and countable' do
    mirrors = js_files.flat_map do |path|
      lines = File.readlines(path)
      lines.each_with_index.flat_map do |line, idx|
        line.scan(/\[([^\[\]]*)\]/).filter_map do |inner|
          items = inner.first.scan(/'([^']*)'|"([^"]*)"/).flatten.compact
          next if items.size < 2 || !items.all? { |i| operator_values.include?(i) }

          # The marker may sit above the line or directly inside the branch below it — both read
          # as belonging to the mirror, so accept a window on either side.
          { rel: Pathname.new(path).relative_path_from(Rails.root).to_s,
            line: idx + 1,
            context: lines[[idx - 6, 0].max..(idx + 4)].join }
        end
      end
    end

    it 'has exactly the four known copies' do
      locations = mirrors.map { |m| "#{m[:rel]}:#{m[:line]}" }

      expect(mirrors.size).to eq(4), lambda {
        "Expected 4 JS operator-group mirrors, found #{mirrors.size}:\n  #{locations.join("\n  ")}\n" \
          'Do not just bump this number. Four hand-maintained copies is already past the point ' \
          'where the vocabulary should be shared instead of copied — render it into a data-* ' \
          'attribute from Ruby and delete the copies.'
      }
    end

    mirrors.each do |mirror|
      it "#{mirror[:rel]}:#{mirror[:line]} carries a back-reference to the Ruby owner" do
        expect(mirror[:context]).to include('SmartFolders::Operators'), lambda {
          "The mirrored operator group at #{mirror[:rel]}:#{mirror[:line]} has no back-reference. " \
            'Deliberate duplication must be marked on BOTH sides so the next change finds the twin.'
        }
      end
    end
  end
end
