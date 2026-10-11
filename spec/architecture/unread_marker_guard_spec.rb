# frozen_string_literal: true

require 'rails_helper'

# "Unread notifications" has one marker: Neo::UnreadMarkerComponent, the red
# pill of the sidebar's Inbox item (or its dot, where a row needs no number).
#
# Until 29.09.2026 fourteen places drew it by hand: red-500 in four sizes, a
# black pill on the phone, and cobalt dots in the cockpit and the inbox. The
# user saw the same fact in three looks on two screens next to each other.
#
# The guard looks for the hand-made version: one class string with a solid red
# fill (bg-red-400 to bg-red-700) and rounded-full. Light washes (bg-red-50 to
# bg-red-300) are error chips and stay free. The admin area has its own style
# guide and no notifications; the style guide pages demonstrate colours.
#
# The exception list may only shrink. Each entry names why its red circle is
# not "unread".
module UnreadMarkerGuard
  SOLID_RED_CIRCLE = /\A(?=.*\bbg-red-[4-7]00\b)(?=.*\brounded-full\b)/

  EXCEPTIONS = {
    'app/views/organisations/ai_overviews/_row.html.erb' =>
      'alert state of an AI overview row (red against amber), not a notification',
    'app/views/organisations/ai_sync_statuses/show.html.erb' =>
      'status dot for failed embeddings, not a notification'
  }.freeze
end

RSpec.describe 'unread notifications use the shared marker', type: :model do
  def scanned_files
    files = %w[app/views app/components app/helpers app/javascript].flat_map do |dir|
      Dir[Rails.root.join(dir, '**/*.{erb,rb,js}')]
    end
    files.map { |file| Pathname.new(file).relative_path_from(Rails.root).to_s }
         .reject { |file| file.start_with?('app/views/admin/', 'app/views/style_guide/') }
         .reject { |file| file == 'app/components/neo/unread_marker_component.rb' }
  end

  def hand_made_markers(file)
    File.read(Rails.root.join(file)).scan(/"[^"\n]*"|'[^'\n]*'/)
        .select { |string| string.match?(UnreadMarkerGuard::SOLID_RED_CIRCLE) }
  end

  it 'draws no red circle by hand outside the component' do
    offenders = (scanned_files - UnreadMarkerGuard::EXCEPTIONS.keys).filter_map do |file|
      found = hand_made_markers(file)
      "#{file}: #{found.join(' | ')}" if found.any?
    end

    expect(offenders).to be_empty, <<~MSG
      Hand-made red circle found. For unread notifications render
      Neo::UnreadMarkerComponent (variant :count or :dot). If it means something
      else, add the file to UnreadMarkerGuard::EXCEPTIONS with the reason.
      #{offenders.join("\n")}
    MSG
  end

  it 'keeps every exception necessary (the list only shrinks)' do
    stale = UnreadMarkerGuard::EXCEPTIONS.keys.select { |file| !File.exist?(Rails.root.join(file)) || hand_made_markers(file).empty? }

    expect(stale).to be_empty, "remove these entries from UnreadMarkerGuard::EXCEPTIONS: #{stale.join(', ')}"
  end

  it 'recognises the hand-made shape it is looking for' do
    expect('w-2 h-2 bg-red-500 rounded-full').to match(UnreadMarkerGuard::SOLID_RED_CIRCLE)
    expect('rounded-full bg-red-600 text-on-fill').to match(UnreadMarkerGuard::SOLID_RED_CIRCLE)
    expect('rounded-full bg-red-100 text-red-800').not_to match(UnreadMarkerGuard::SOLID_RED_CIRCLE)
  end
end
