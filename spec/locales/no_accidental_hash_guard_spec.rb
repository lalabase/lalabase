# frozen_string_literal: true

require 'rails_helper'

# What: No translation key carries a space.
# Why:  A sentence with "colon space" in it is no longer text in YAML but a mapping.
#       Out of
#
#         - Wir haben Unteraufgaben, aber nur eine Ebene: ein Baum war das Problem.
#
#       comes a hash whose key is half the sentence. Nothing breaks: the file parses,
#       the application starts, the test run stays green, and the page shows the
#       visitor `{:"Wir haben Unteraufgaben..."=>"ein Baum war das Problem."}`.
#
#       That is exactly what stood on /de/vergleich/jira and /en/comparison/jira on
#       22.08.2026, in both languages, found by a human and by no spec.
#
#       The test checks the STRUCTURE, not the colon: a colon in a quoted string is
#       perfectly fine and appears in dozens of places. Only the result is wrong, and
#       you recognise it by a key that suddenly carries a space. Locale keys are
#       snake_case, always.
RSpec.describe 'Locale files', type: :model do
  def keys_with_spaces(node, path = [])
    case node
    when Hash
      node.flat_map do |key, value|
        if key.is_a?(String) && key.include?(' ')
          ["#{path.join('.')} => #{key[0, 80]}"]
        else
          keys_with_spaces(value, path + [key.to_s])
        end
      end
    when Array
      node.each_with_index.flat_map { |value, i| keys_with_spaces(value, path + ["[#{i}]"]) }
    else
      []
    end
  end

  it 'turn no sentence into a mapping by accident' do
    treffer = Dir[Rails.root.join('config/locales/**/*.yml')].sort.flat_map do |file|
      inhalt = YAML.unsafe_load_file(file)
      kurz = Pathname(file).relative_path_from(Rails.root)
      keys_with_spaces(inhalt).map { |fund| "#{kurz}: #{fund}" }
    end

    expect(treffer).to be_empty,
                       "Diese Zeilen sind in YAML ein Mapping geworden statt ein Text.\n" \
                       "Der Besucher sieht den Hash im Klartext. Abhilfe: den Wert in \n" \
                       "doppelte Anführungszeichen setzen.\n\n#{treffer.join("\n")}"
  end
end
