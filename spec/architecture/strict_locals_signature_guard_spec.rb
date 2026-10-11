# frozen_string_literal: true

require 'rails_helper'

# Rails 8.0.5.1 tightened the magic comment that turns a view into a strict-locals
# template:
#
#   8.0.2    /\#\s+locals:\s+\((.*)\)/
#   8.0.5.1  /\#\s+locals:\s+\((.*?)\)(?=\s*-?%>|\s*$)/m
#   8.1.4    unchanged
#
# The closing parenthesis must now be followed by `%>` (or `-%>`) or a line end. Six
# views used to continue with prose right there ("<%# locals: (meeting:) — what this view
# does ... %>"). Under the new regex the lazy group runs on until some later `)` that
# happens to sit at a line end, the captured "signature" is prose, and the template raises
# ActionView::SyntaxErrorInTemplate: a 500 on the page. Only one of the six views was
# rendered by any spec in the CI list; the other five would have shipped broken.
#
# This guard does what ActionView does, for every view, at CI time: extract the signature
# with ActionView's own regex and check that it compiles as a Ruby parameter list. It
# also flags the quieter failure, a comment that clearly means to be strict but no longer
# matches at all (the view then silently stops being strict).
RSpec.describe 'Strict-locals signatures in app/views', type: :model do
  let(:views) { Dir.glob(Rails.root.join('app/views/**/*.erb')) }

  # The magic comment as a human writes it, before ActionView decides whether it counts.
  let(:intended_strict) { /<%#\s*locals:\s*\(/ }

  def signature_for(source)
    source.match(ActionView::Template::STRICT_LOCALS_REGEX)&.[](1)&.rstrip
  end

  # Compile only, never run: the signature becomes a method parameter list inside
  # ActionView, so a lambda with the same list is the exact same syntax question.
  def parameter_list?(signature)
    RubyVM::InstructionSequence.compile("->(#{signature}) {}")
    true
  rescue SyntaxError
    false
  end

  def offence_for(source)
    return nil unless source.match?(intended_strict)

    signature = signature_for(source)
    if signature.nil?
      "locals comment found, but ActionView #{ActionView.version} does not recognise it (text after the closing parenthesis?)"
    elsif !parameter_list?(signature)
      "signature is not a parameter list: #{signature.truncate(70)}"
    end
  end

  it 'declares every strict view with a signature ActionView can compile' do
    offenders = views.filter_map do |path|
      offence = offence_for(File.read(path))
      "#{Pathname.new(path).relative_path_from(Rails.root)}: #{offence}" if offence
    end

    expect(offenders).to be_empty, <<~MESSAGE
      These views would raise ActionView::SyntaxErrorInTemplate (or silently lose strict
      locals) under Rails #{Rails.version}. Close the signature with %> and put the prose
      in a second <%# ... %> comment below it:

      #{offenders.join("\n")}
    MESSAGE
  end

  # Self-tests: a guard that scans text must show it can tell a violation from a pass.
  it 'catches the pattern that broke six views on 28.08.2026' do
    source = <<~ERB
      <%# locals: (meeting:) — "Verknüpfte Tickets" on the meeting detail (Gespräche
         backlinks). Explains the section in prose, right after the signature. %>
      <div></div>
    ERB
    expect(offence_for(source)).to be_present
  end

  it 'accepts a closed signature with the prose in a second comment' do
    source = <<~ERB
      <%# locals: (meeting:, can_write:, just_finished: nil, **) %>
      <%# "Verknüpfte Tickets" on the meeting detail (Gespräche backlinks). %>
      <div></div>
    ERB
    expect(offence_for(source)).to be_nil
  end

  it 'accepts the trim spelling and an empty signature' do
    expect(offence_for("<%# locals: (ticket:) -%>\n<div></div>\n")).to be_nil
    expect(offence_for("<%# locals: () %>\n<div></div>\n")).to be_nil
  end

  it 'ignores comments that never carried a parenthesised signature' do
    expect(offence_for("<%# locals: none, this partial reads instance variables %>\n")).to be_nil
  end
end
