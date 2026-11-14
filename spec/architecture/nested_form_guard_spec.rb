# frozen_string_literal: true

require 'rails_helper'

# Guard: no form inside a form.
#
# A `button_to`, or a Neo button with `form: { ... }` (which renders a
# `button_to`), is a form of its own. Written inside a `form_with` block it is a
# form within a form, which HTML does not have. What the browser makes of it
# depends on how the markup arrives:
#
#   * through a Turbo Stream (a <template>), the inner form survives, and
#     Chrome stops its submit event at the OUTER form. Turbo listens further up
#     and never sees it: no `data-turbo-confirm` question, no Turbo request. The
#     browser posts the inner form itself.
#   * through a page or a frame load, the parser drops the inner <form> tag and
#     its fields join the outer form, a second `_method` among them.
#
# Until 13.11.2026 the delete buttons of the meeting and the note edit forms
# stood like that: one click deleted the record, the question never came. The
# request specs saw complete markup; only a browser spec noticed, and that one
# was red for two weeks without a known cause.
#
# The way out is a link with `data: { turbo_method: :delete }` and the button's
# `confirm:` (tickets/_writing_surface, meetings/_meeting_edit, notes/_note_edit):
# Turbo builds the form at the click, outside the one on the page.
#
# A tripwire, not a proof. It reads one template at a time and follows its ERB
# blocks. ⚠️ It does NOT see a partial or a component rendered inside a form
# that brings a form of its own, nor a <form> written out as a tag. Those are
# for the browser spec of the page (spec/system/note_edit_delete_spec.rb).
#
# No allowlist: it starts at zero.
RSpec.describe 'Nested form guard' do
  let(:scanned_files) do
    %w[app/views/**/*.erb app/components/**/*.erb]
      .flat_map { |glob| Dir[Rails.root.join(glob)] }
      .sort
  end

  let(:erb_tag) { /<%(=|-|#)?(.*?)-?%>/m }
  let(:block_opener) { /\bdo\s*(\|[^|]*\|)?\s*\z/ }
  let(:statement_opener) { /\A(if|unless|case|while|until|begin|for)\b/ }
  let(:form_builder) { /\b(form_with|form_for|form_tag)\b/ }
  let(:form_of_its_own) { /\bbutton_to\b|\bform:\s*\{/ }

  # "relative/path.erb:LINE" for every form of its own that stands inside a
  # form block of the same template.
  def nested_forms(source)
    open_blocks = []
    source.to_enum(:scan, erb_tag).filter_map do
      match = Regexp.last_match
      next if match[1] == '#'

      code = match[2].strip
      line = source[0...match.begin(0)].count("\n") + 1
      inside = open_blocks.include?(:form) && code.match?(form_of_its_own)

      if code.match?(/\Aend\b/)
        open_blocks.pop
      elsif !code.match?(/\A(else|elsif|when|in|rescue|ensure)\b/) && (code.match?(block_opener) || code.match?(statement_opener))
        open_blocks.push(code.match?(form_builder) && code.match?(block_opener) ? :form : :other)
      end

      line if inside
    end
  end

  it 'finds the two shapes it is written for, and leaves their repair alone' do
    button_in_form = <<~ERB
      <%= form_with(model: record) do |form| %>
        <% if allowed %>
          <%= render Neo::Buttons::ButtonComponent.new(confirm: 'Sure?', form: { action: path, method: :delete }) do %>
            Delete
          <% end %>
        <% end %>
        <%= button_to 'Remove', path, method: :delete %>
      <% end %>
      <%= button_to 'Outside', path, method: :delete %>
    ERB
    link_in_form = <<~ERB
      <%= form_with(model: record) do |form| %>
        <%= render Neo::Buttons::ButtonComponent.new(confirm: 'Sure?', url: path, data: { turbo_method: :delete }) do %>
          Delete
        <% end %>
      <% end %>
    ERB

    expect(nested_forms(button_in_form)).to eq([3, 7])
    expect(nested_forms(link_in_form)).to be_empty
  end

  it 'no template puts a button_to or a form: button inside a form block' do
    expect(scanned_files.size).to be > 500

    offenders = scanned_files.flat_map do |file|
      relative = Pathname.new(file).relative_path_from(Rails.root).to_s
      nested_forms(File.read(file)).map { |line| "#{relative}:#{line}" }
    end

    expect(offenders).to be_empty, <<~MSG
      A form of its own inside a form block:

      #{offenders.map { |offender| "  - #{offender}" }.join("\n")}

      A button_to (or a Neo button with form:) within form_with is a form within
      a form. From a Turbo Stream Chrome stops its submit event at the outer form:
      Turbo never asks its question and the browser posts the form itself.
      Use a link with data: { turbo_method: ... } and the button's confirm:, or
      move the button behind the end of the form.
    MSG
  end
end
