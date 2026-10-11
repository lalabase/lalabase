# frozen_string_literal: true

require 'rails_helper'

# What: code that asks for time rights reads TimeSessionPermission only through
#   .backed_by_project_access, and only the Team page's settings form uses
#   User#time_session_permission_for.
# Why: the time row is a second grant on top of project membership, and until
#   27.09.2026 it outlived every exit from a project (audit of 26.09.2026). Nine
#   readers asked the row alone, so a removed member kept reading and booking
#   time. One more asked the settings form's helper, whose unsaved default row
#   answers can_view_own for anyone. A rule every reader has to remember is not a
#   rule, so the bare read is what this guard refuses.
module TimeSessionPermissionGuard
  # The model itself defines the scope and is not a reader.
  MODEL = 'app/models/time_session_permission.rb'

  # Safe by construction: the rule itself, and a new unsaved row for display.
  SAFE_CHAIN = /\A\.(?:backed_by_project_access|new)\b/

  # Shrink-only: every entry names why its bare access is safe. An entry without
  # a finding left fails too, so a cleaned file must leave the list.
  ALLOWED = {
    'app/models/user/authorization.rb' =>
      "time_session_permission_for, the settings form's find_or_initialize_by (a writer)",
    'app/models/project_permission.rb' => 'deletes the rows when the project membership ends',
    'app/models/membership.rb' => 'deletes the rows when the organisation membership ends'
  }.freeze

  # The only caller of the settings form's helper besides its definition.
  FORM_HELPER_CALLERS = %w[app/controllers/organisations/project_permissions_controller.rb].freeze

  STRING_LITERAL = /'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"/
  # The association with or without a receiver (not the has_many symbol), or the class.
  ACCESS = /(?<![:\w])time_session_permissions\b|\bTimeSessionPermission\b/

  # [line number, text] of every bare access in one file's source
  def self.findings(source)
    lines = source.lines
    lines.each_with_index.filter_map do |line, index|
      next if comment?(line)

      [index + 1, line.strip] if bare_access?(line, lines[index + 1]) || bare_join?(line)
    end
  end

  def self.comment?(line)
    line.match?(/\A\s*(?:#|<%#)/)
  end

  # An access not followed by a safe call, on this line or, for a chain broken
  # after it, on the next one.
  def self.bare_access?(line, next_line)
    code = line.gsub(STRING_LITERAL, '""')
    code.to_enum(:scan, ACCESS).any? do
      rest = Regexp.last_match.post_match.strip
      rest = next_line.to_s.strip if rest.empty?
      !rest.match?(SAFE_CHAIN)
    end
  end

  def self.bare_join?(line)
    line.match?(/JOIN\s+time_session_permissions\b/i)
  end

  def self.form_helper_call?(line)
    !comment?(line) && line.match?(/\.time_session_permission_for\b/)
  end

  def self.files
    Dir[Rails.root.join('app/**/*.{rb,erb}')]
      .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }
      .reject { |file| file == MODEL }
      .sort
  end
end

RSpec.describe 'Time right reads go through TimeSessionPermission.backed_by_project_access', :ci_guard,
               type: :architecture do
  it 'finds no bare read of the time rights outside the allow list' do
    offenders = TimeSessionPermissionGuard.files.reject { |file| TimeSessionPermissionGuard::ALLOWED.key?(file) }
                                          .flat_map do |file|
      TimeSessionPermissionGuard.findings(File.read(Rails.root.join(file)))
                                .map { |number, text| "#{file}:#{number}: #{text}" }
    end

    expect(offenders).to be_empty,
                         "These read time rights without the project access behind them:\n" \
                         "#{offenders.join("\n")}\n\n" \
                         'Use user.time_session_permissions.backed_by_project_access (or ' \
                         'TimeSessionPermission.backed_by_project_access): a row counts only while ' \
                         'the person is still on the project.'
  end

  it 'keeps no allow-list entry that no longer has a finding' do
    stale = TimeSessionPermissionGuard::ALLOWED.keys.select do |file|
      path = Rails.root.join(file)
      !path.exist? || TimeSessionPermissionGuard.findings(path.read).empty?
    end

    expect(stale).to be_empty, "Remove these from TimeSessionPermissionGuard::ALLOWED, they are clean now:\n#{stale.join("\n")}"
  end

  it "leaves the settings form's helper to the settings form" do
    callers = TimeSessionPermissionGuard.files.select do |file|
      File.readlines(Rails.root.join(file)).any? { |line| TimeSessionPermissionGuard.form_helper_call?(line) }
    end

    expect(callers).to match_array(TimeSessionPermissionGuard::FORM_HELPER_CALLERS),
                       'User#time_session_permission_for builds an unsaved default row that grants ' \
                       'can_view_own to anyone. Readers ask TimeSessions::ViewingScope instead.'
  end

  describe 'what counts as a bare read' do
    def bare?(source)
      TimeSessionPermissionGuard.findings(source).any?
    end

    it 'flags reads of the row alone' do
      expect(bare?("user.time_session_permissions.find_by(project: project)\n")).to be(true)
      expect(bare?("@user.time_session_permissions\n  .joins(:project)\n")).to be(true)
      expect(bare?("TimeSessionPermission.where(project_id: id)\n")).to be(true)
      expect(bare?("time_session_permissions.find_by(project: project)\n")).to be(true)
      expect(bare?("scope.joins('INNER JOIN time_session_permissions ON x')\n")).to be(true)
    end

    it 'lets the rule and a new unsaved row pass' do
      expect(bare?("user.time_session_permissions.backed_by_project_access.find_by(project: p)\n")).to be(false)
      expect(bare?("user.time_session_permissions\n  .backed_by_project_access\n")).to be(false)
      expect(bare?("TimeSessionPermission.backed_by_project_access.where(project_id: id)\n")).to be(false)
      expect(bare?("TimeSessionPermission.new(project: p, user: u)\n")).to be(false)
    end

    it 'ignores comments, strings and the association declaration' do
      expect(bare?("# user.time_session_permissions used to be read here\n")).to be(false)
      expect(bare?("'time_session_permissions' => 'Org-granted rights'\n")).to be(false)
      expect(bare?("has_many :time_session_permissions, dependent: :destroy\n")).to be(false)
    end
  end
end
