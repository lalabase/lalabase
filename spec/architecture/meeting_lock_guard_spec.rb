# frozen_string_literal: true

require 'rails_helper'

# What: a write that was authorized against a project takes the meeting's row
#   lock through Meeting#lock_in_project!, which answers whether the meeting is
#   still in that project. A bare lock on a meeting is refused outside the model.
# Why: Actors::MoveMeeting holds that lock while it moves a meeting. Three review
#   rounds of the move (lalabase/lalabase#45) found six writes that had been
#   authorized against the old project and still landed after a move: an edit,
#   a delete, a ticket link, a booking, an analysis publication, a second move.
#   Each had been fixed by hand with "lock, then compare the project". A rule
#   that has to be remembered at every write is not a rule.
# Not seen: a write that takes no lock at all. WRITERS pins the ones that exist;
#   a new write on a meeting is for the person who reads the diff.
module MeetingLockGuard
  ROOTS = %w[app lib].freeze
  MODEL = 'app/models/meeting.rb'

  # A lock taken directly on a meeting: @meeting.lock!, meeting&.lock!,
  # Meeting.lock, project.meetings.lock. Not lock_in_project!, not the lock of
  # a meeting's analyses (meeting_analyses.lock).
  BARE_LOCK = /(?:@meeting|\bmeetings?|\bMeeting)\b&?\.lock(?:!|\b)(?!_)/

  # They lock and then authorize again, under the lock, against the project the
  # meeting is in NOW: safe after a move too, and their meeting may come from a
  # chat rather than from a project.
  ALLOWED = {
    'app/services/actors/accept_ticket_suggestion.rb' =>
      'asks MeetingPolicy#update? and tickets write in the current project under the lock',
    'app/services/actors/start_ticket_suggestion_run.rb' =>
      'asks MeetingPolicy#update? under the lock; the meeting may come from a chat reference'
  }.freeze

  WRITERS = %w[
    app/services/actors/move_meeting.rb
    app/services/actors/save_meeting.rb
    app/services/actors/save_meeting_analysis.rb
    app/services/actors/save_time_session.rb
    app/controllers/organisations/meeting_ticket_links_controller.rb
    app/controllers/organisations/meetings_controller.rb
  ].freeze

  def self.files
    ROOTS.flat_map { |root| Dir[Rails.root.join(root, '**', '*.{rb,erb}')] }
         .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }
         .reject { |path| path == MODEL }
  end

  def self.bare_locks(source)
    source.each_line.with_index(1).filter_map do |line, number|
      next if line.strip.start_with?('#')

      [number, line.strip] if line.match?(BARE_LOCK)
    end
  end
end

RSpec.describe 'Meeting locks go through Meeting#lock_in_project!', type: :architecture do
  it 'finds no bare lock on a meeting beyond the allow list' do
    found = MeetingLockGuard.files.filter_map do |file|
      next if MeetingLockGuard::ALLOWED.key?(file)

      hits = MeetingLockGuard.bare_locks(File.read(Rails.root.join(file)))
      "#{file}:\n#{hits.map { |n, text| "  #{n}: #{text}" }.join("\n")}" if hits.any?
    end

    expect(found).to be_empty,
                     "These lock a meeting directly:\n#{found.join("\n")}\n\n" \
                     'Use meeting.lock_in_project!(authorized_project_id) and treat false as ' \
                     '"the meeting is gone from this project".'
  end

  it 'keeps the allow list to files that still lock and authorize again' do
    MeetingLockGuard::ALLOWED.each_key do |file|
      hits = MeetingLockGuard.bare_locks(File.read(Rails.root.join(file)))

      expect(hits).to be_present, "#{file} no longer locks directly: remove it from ALLOWED"
    end
  end

  it 'has every known writer call lock_in_project!' do
    missing = MeetingLockGuard::WRITERS.reject { |file| File.read(Rails.root.join(file)).include?('lock_in_project!(') }

    expect(missing).to be_empty, "These writers no longer take the lock: #{missing.join(', ')}"
  end

  describe 'the matcher' do
    it 'sees the forms a direct lock takes' do
      ['@meeting.lock!', '@time_session.meeting&.lock!', 'meeting.lock!',
       'Meeting.lock.find(id)', 'project.meetings.lock.find(id)'].each do |code|
        expect(code).to match(MeetingLockGuard::BARE_LOCK), code
      end
    end

    it 'leaves the helper and the lock of an analysis alone' do
      ['@meeting.lock_in_project!(@project.id)', '@meeting.meeting_analyses.lock.find_by(id: @id)',
       'meeting_lock = true'].each do |code|
        expect(code).not_to match(MeetingLockGuard::BARE_LOCK), code
      end
    end
  end
end
