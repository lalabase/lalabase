# frozen_string_literal: true

require 'rails_helper'

# S3a T4 (assistant plan §7.7, the fourth trap).
#
# `turbo-visit-control` is read by Turbo ONLY as a <meta> tag in the document
# head. As a LINK attribute -- data-turbo-visit-control="reload" -- nobody reads
# it: it looks like a deliberate full reload, it reads like one in review, and it
# does nothing at all. Five sidebar links carried it for years against a stale
# detail view that turbo_cache_controller actually handles.
#
# It matters now because the assistant's companion panel is a
# data-turbo-permanent node: it survives Turbo DRIVE visits and dies on a full
# page load, together with the typed draft. The day somebody "repairs" one of
# these dead attributes into a real reload, the panel starts dropping what people
# have written, and the cause will not be anywhere near the symptom.
#
# The meta-tag form stays allowed -- that one works, and one page uses it on
# purpose.
#
# ⚠️ This greps files, so it cannot tell markup from a comment ABOUT the markup.
# Prose that needs to name the dead form spells it out in words instead of
# writing it out (see the note in common/_navigation_item.erb). That is the price
# of a guard with no allowlist, and the cheaper half of the trade.
RSpec.describe 'turbo-visit-control as a link attribute', type: :model do
  # app/javascript and app/controllers are in the list because markup is written
  # there too (Stimulus templates, the inline heredocs CLAUDE.md still lists in
  # controller actions) -- the attribute is just as dead there.
  let(:search_roots) { %w[app/views app/components app/helpers app/javascript app/controllers] }

  # Two spellings, one expression. `... :` is the Ruby hash form
  # (data: { 'turbo-visit-control': 'reload' }); `... =` is the raw markup form
  # (data-turbo-visit-control="reload"), which the comment above names as THE
  # dead one and which the first version of this guard did not match at all.
  #
  # The meta tag survives both: there the name is followed by a quote and then
  # `content`, never by a colon or an equals sign.
  let(:dead_attribute) { /['"]?turbo[-_]visit[-_]control['"]?\s*[:=]/ }

  it 'appears nowhere in the codebase' do
    offenders = search_roots.flat_map { |root| Dir.glob(Rails.root.join(root, '**', '*')) }
                            .select { |path| File.file?(path) }
                            .select { |path| File.read(path).match?(dead_attribute) }
                            .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }

    expect(offenders).to be_empty, <<~MESSAGE
      data-turbo-visit-control on a link is a no-op (Turbo reads it only as a
      <meta> tag). Either drop it, or -- if a real full reload is genuinely
      wanted -- add the meta tag to that page AND note what it does to the
      assistant's permanent panel, which does not survive a full load.

      Found in:
      #{offenders.map { |o| "  #{o}" }.join("\n")}
    MESSAGE
  end

  # The counter-example, so the guard above cannot be satisfied by deleting the
  # working mechanism along with the dead one.
  it 'still permits the meta-tag form that actually works' do
    knowledge_index = Rails.root.join('app/views/organisations/knowledge/index.html.erb').read

    expect(knowledge_index).to include('<meta name="turbo-visit-control" content="reload">')
    expect(knowledge_index).not_to match(dead_attribute)
  end

  # The expression itself, against both spellings and the one that must pass.
  # Without this the guard could quietly stop matching a form and still be green,
  # which is exactly what happened to its first version.
  it 'matches both dead spellings and not the meta tag' do
    expect(%(data: { 'turbo-visit-control': 'reload' })).to match(dead_attribute)
    expect(%(data-turbo-visit-control="reload")).to match(dead_attribute)
    expect(%(<meta name="turbo-visit-control" content="reload">)).not_to match(dead_attribute)
  end
end
