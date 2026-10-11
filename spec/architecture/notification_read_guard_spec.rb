# frozen_string_literal: true

require 'rails_helper'

# What: code that lists, counts or opens notifications reaches them only through the
#   inbox rule: Notification.accessible_for / .inbox_unread / .readable, or Pundit's
#   policy_scope (NotificationPolicy::Scope asks accessible_for).
# Why: the rule (active projects the person may read, per AREA of the subject;
#   Notification::AREA_BY_NOTIFIABLE_TYPE) has to be applied at every read. When it
#   became area-aware on 2026-10-07, eight readers turned out to skip it: the project
#   dashboard listed notifications about tickets the person could no longer open,
#   titles included, and five counters promised rows the inbox did not show (reviews
#   of gboyke/lalabase#970 and #975). A rule that has to be remembered at every read
#   is not a rule, so the bare read is what this guard refuses.
module NotificationReadGuard
  DIRECTORIES = %w[controllers services queries mailers components views presenters jobs helpers].freeze

  # Any receiver's notifications (an association read), an association loaded along, or
  # the table itself.
  READ = /\.notifications\b(?![?_!])|(?:includes|joins|left_joins|preload|eager_load)\([^)]*:notifications\b|
          \bNotification\s*\.(?:where|unread|channel_in_app|all|find_by|find|for_user|inbox|unscoped|joins|
          left_joins|pluck|select|includes|order|group|count|exists\?|recent|in_app)\b/x

  # The name of a Turbo stream, not a read.
  NOT_A_READ = /\bStreams\.notifications\b/

  SAFE = /accessible_for|inbox_unread|Notification\.readable|policy_scope/

  STRING_LITERAL = /'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"/
  INTERPOLATION = /\#\{([^}]*)\}/

  ALLOWED = {
    'app/components/dashboard/recent_tickets_component.rb' =>
      [1, 'unread count per ticket, shown only next to tickets the list already shows; the list renders only ' \
          'with the tickets area (should_render?), the same filter TicketPolicy::Scope applies'],
    'app/components/dashboard/smart_folder_tickets_component.rb' =>
      [1, 'unread count per ticket, shown only next to tickets the list already shows'],
    'app/controllers/organisations/post_reactions_controller.rb' =>
      [1, 'unread count per ticket for the ticket list it re-renders (tickets already authorized)'],
    'app/controllers/organisations/tickets_controller.rb' =>
      [1, 'unread count per ticket for the ticket list (tickets already authorized)'],
    'app/views/organisations/tickets/_ticket_display.html.erb' =>
      [1, 'unread marker of the ticket being displayed (ticket already authorized)'],
    'app/controllers/organisations/notifications_controller.rb' =>
      [5, 'set_notification_for_open (2): its own row is authorized (NotificationPolicy, accessible_for) ' \
          'before anything is shown; a foreign row only leads on to a ticket the person may read ' \
          '(policy show?); the broadcast after a mark-read re-sends rows ' \
          'found through policy_scope; @new_activities reads the rows of a ticket that was authorized ' \
          'first; @presenter.notifications is the inbox list the presenter built through policy_scope'],
    'app/controllers/api/v1/notifications_controller.rb' =>
      [1, 'writes: marks rows read whose ids came from the inbox query'],
    'app/controllers/organisations/projects_controller.rb' =>
      [1, 'writes: archives the notifications of a project being archived'],
    'app/jobs/project_deletion_job.rb' => [1, 'writes: deletes the notifications of a deleted project'],
    'app/jobs/email_delivery_job.rb' =>
      [1, 'loads its own row by id; deliverable_to_recipient? asks accessible_for before any mail goes out'],
    'app/presenters/inbox/master_list_presenter.rb' =>
      [1, 'representatives by id out of the already filtered inbox relation'],
    'app/services/dashboard/daily_briefing.rb' =>
      [1, 'uses notified subjects only to HIDE activities from another lane, shows none of them'],
    'app/services/notifications/fanout_service.rb' => [1, 'writes: finds the group a new notification joins'],
    'app/services/notifications/group_key_builder.rb' => [1, 'writes: finds the group a new notification joins'],
    'app/services/notifications/inbox_query.rb' =>
      [1, 'the raw recipient relation; within_reach puts Notification.readable on it per organisation'],
    'app/services/notifications/mark_ticket_read.rb' => [3, 'writes: marks the rows of an opened ticket read'],
    'app/services/posts/mark_read.rb' => [1, 'writes: marks the rows of a read comment read'],
    'app/services/tickets/mover.rb' => [1, 'writes: moves the notifications of a moved ticket along'],
    'app/services/posts/excerpt_redaction.rb' => [1, 'writes: redacts excerpts of a deleted or private comment'],
    'app/services/notifications/unread_signals.rb' =>
      [1, 'a grouped pre-count that only decides WHERE to ask; each count shown is inbox_unread'],
    'app/views/organisations/_cockpit_action_summary.html.erb' =>
      [1, 'slice.notifications: the cockpit slice, built from Notification.inbox_unread'],
    'app/views/organisations/_cockpit_row.html.erb' =>
      [1, 'slice.notifications: the cockpit slice, built from Notification.inbox_unread'],
    'app/views/organisations/notifications/_master_list.html.erb' =>
      [1, 'presenter.notifications: the inbox list the presenter built through policy_scope'],
    'app/services/notifications/shared/scope_filter.rb' =>
      [2, 'dead code, never instantiated (pinned in scope_filter_spec.rb); goes with its deletion']
  }.freeze

  # What the guard does NOT see, so a reviewer looks for it: SQL text that names the
  # table (FROM notifications), app/models, app/policies, app/channels and lib/, a read
  # through send or a variable holding the class, and a chain broken after an operator
  # rather than before a leading dot.

  # [[line number, code]]: Ruby line by line; ERB reduced to the code of its tags
  # (comments <%# left out), each tag on the line it starts, so a tag inside an
  # attribute value counts like any other.
  def self.code_lines(source, erb:)
    return source.lines.each_with_index.map { |line, index| [index + 1, line] } unless erb

    source.to_enum(:scan, /<%(?!#)=?-?(.*?)-?%>/m).map do
      match = Regexp.last_match
      [source[0...match.begin(0)].count("\n") + 1, "#{match[1].tr("\n", ' ')}\n"]
    end
  end

  # The code of a line without its strings and its comment; interpolations stay,
  # they are code.
  def self.clean(line)
    interpolated = line.scan(INTERPOLATION).flatten
    code = line.gsub(STRING_LITERAL, '""').sub(/#.*/, '')
    [code, *interpolated].join(';')
  end

  # [line number, text] of every bare read in one file's source. A statement is a
  # line split at ";", the last part carrying the lines that continue it with a
  # leading dot. A safe word counts only inside the same statement, never in a
  # comment or a neighbouring statement.
  def self.findings(source, erb: false)
    lines = code_lines(source, erb: erb)
    lines.each_with_index.filter_map do |(number, line), index|
      next if line.strip.start_with?('.')

      parts = clean(line).split(';')
      parts << '' if parts.empty?
      following = index + 1
      while following < lines.size && lines[following][1].strip.start_with?('.')
        parts[-1] = "#{parts[-1]} #{clean(lines[following][1])}"
        following += 1
      end
      [number, line.strip] if parts.any? { |part| bare?(part) }
    end
  end

  def self.bare?(statement)
    statement.gsub(NOT_A_READ, '').match?(READ) && !statement.match?(SAFE)
  end

  def self.files
    DIRECTORIES.flat_map { |dir| Dir[Rails.root.join("app/#{dir}/**/*.{rb,erb}")] }
               .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }.sort
  end

  def self.counts
    files.index_with { |file| findings(File.read(Rails.root.join(file)), erb: file.end_with?('.erb')).size }
         .reject { |_, n| n.zero? }
  end

  # Files with more bare reads than the list allows.
  def self.over(counts, allowed)
    counts.select { |file, count| count > allowed.fetch(file, [0]).first }
  end

  # Entries that allow more than is left (a fixed read must lower its entry).
  def self.stale(counts, allowed)
    allowed.filter_map { |file, (limit, _why)| file if counts.fetch(file, 0) < limit }
  end
end

RSpec.describe 'Notification reads go through the inbox rule', type: :architecture do
  it 'finds no bare read beyond the allow list' do
    over = NotificationReadGuard.over(NotificationReadGuard.counts, NotificationReadGuard::ALLOWED).map do |file, count|
      found = NotificationReadGuard.findings(File.read(Rails.root.join(file)), erb: file.end_with?('.erb'))
      "#{file} (#{count}, allowed #{NotificationReadGuard::ALLOWED.fetch(file, [0]).first}):\n" +
        found.map { |n, text| "  #{n}: #{text}" }.join("\n")
    end

    expect(over).to be_empty,
                    "These read notifications without the inbox rule:\n#{over.join("\n")}\n\n" \
                    'Use Notification.inbox_unread(user, organisation) or .accessible_for(user, organisation) ' \
                    '(or policy_scope) and narrow from there; it applies the areas ' \
                    '(Notification::AREA_BY_NOTIFIABLE_TYPE) and the active projects.'
  end

  it 'keeps every allow-list count at what is actually left' do
    stale = NotificationReadGuard.stale(NotificationReadGuard.counts, NotificationReadGuard::ALLOWED)

    expect(stale).to be_empty, "Lower these entries of NotificationReadGuard::ALLOWED:\n#{stale.join("\n")}"
  end

  describe 'the count checks' do
    let(:allowed) { { 'a.rb' => [2, 'why'], 'b.rb' => [1, 'why'] } }

    it 'reports a file over its entry, or with no entry at all' do
      expect(NotificationReadGuard.over({ 'a.rb' => 3, 'b.rb' => 1, 'c.rb' => 1 }, allowed).keys)
        .to eq(%w[a.rb c.rb])
    end

    it 'reports an entry above what is left, by one already' do
      expect(NotificationReadGuard.stale({ 'a.rb' => 1, 'b.rb' => 1 }, allowed)).to eq(['a.rb'])
      expect(NotificationReadGuard.stale({ 'a.rb' => 2 }, allowed)).to eq(['b.rb'])
    end
  end

  describe 'what counts as a bare read' do
    def bare?(source, erb: false)
      NotificationReadGuard.findings(source, erb: erb).any?
    end

    it 'flags reads that take every row' do
      expect(bare?("user.notifications.channel_in_app.unread.count\n")).to be(true)
      expect(bare?("current_user.notifications\n  .where(project: project)\n  .count\n")).to be(true)
      expect(bare?("Notification\n  .where(recipient_id: ids)\n  .group(:project_id).count\n")).to be(true)
      expect(bare?("@notification.recipient.notifications.unread.count\n")).to be(true)
      expect(bare?("member.notifications.unread.size\n")).to be(true)
      expect(bare?("slice.notifications.each { |n| n }\n")).to be(true)
      expect(bare?("User.includes(:notifications).where(id: ids)\n")).to be(true)
      expect(bare?("Notification.unscoped.where(recipient: user).count\n")).to be(true)
    end

    it 'reads a chain broken before the association as one statement' do
      expect(NotificationReadGuard.findings("current_user\n  .notifications\n  .unread.count\n")).to eq([[1, 'current_user']])
      expect(bare?("current_user\n  .notifications\n  .accessible_for(current_user, organisation)\n")).to be(false)
    end

    it 'does not take a safe word from a comment or a neighbouring statement' do
      expect(bare?("user.notifications.unread.count # policy_scope not needed here\n")).to be(true)
      expect(bare?("a = user.notifications.unread.count; b = policy_scope(x)\n")).to be(true)
    end

    it 'reads code inside strings and ERB attributes' do
      expect(bare?("label = \"\#{current_user.notifications.unread.count} new\"\n")).to be(true)
      expect(bare?(%(<span data-count="<%= current_user.notifications.unread.count %>"></span>\n), erb: true))
        .to be(true)
      expect(bare?(%(<p>It's <%= current_user.notifications.count %> o'clock</p>\n), erb: true)).to be(true)
    end

    it 'lets the inbox rule and the policy scope pass' do
      expect(bare?("Notification.inbox_unread(user, organisation).where(project: project).count\n")).to be(false)
      expect(bare?("user.notifications\n  .accessible_for(user, organisation)\n")).to be(false)
      expect(bare?("policy_scope(current_user.notifications).find_by(id: id)\n")).to be(false)
      expect(bare?("Notification.readable(rel, user, organisation)\n")).to be(false)
    end

    it 'ignores comments, strings and names that only mention notifications' do
      expect(bare?("# user.notifications used to be read here\n")).to be(false)
      expect(bare?("Notifications::Streams.notifications(user, organisation)\n")).to be(false)
      expect(bare?("t('user.notifications.title')\n")).to be(false)
      expect(bare?("<%# current_user.notifications.count %>\n", erb: true)).to be(false)
      expect(bare?("user.notifications_enabled?\n")).to be(false)
    end
  end
end
