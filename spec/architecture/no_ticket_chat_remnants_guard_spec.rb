# frozen_string_literal: true

require 'rails_helper'

# S4-T1 (assistant plan §10 S4, §12): the ticket chat is dissolved, and this is
# the invariant that keeps it dissolved. "Kein Lesepfad greift noch auf
# chats.ticket_id zu" is not a grep somebody runs once: a remnant that slips
# back in (a merge from an old branch, a helper resurrected out of habit)
# renders fine and throws nothing, it just re-opens a surface the plan closed.
#
# The scan runs over app/, lib/, config/ and the schema WHOLESALE, not over a
# list of the files that carried the ticket chat. The list was the shape of the
# problem: Rev. 2 of the plan named four things to remove, the inventory for
# Rev. 11 found thirty places.
RSpec.describe 'No ticket-chat remnants (S4-T1 guard)', type: :model do
  # Code vocabulary AND prose ("Ticket-Chat", "ticket thread"): a stale comment that
  # still explains the code by a surface that no longer exists is a remnant too.
  # `ticket_chat_plan` is the historical design document, referenced by name from a
  # rake task; a document is allowed to keep its title. `ticket_thread` carries a
  # LEADING anchor only (email_ticket_thread passes); every token that STARTS with
  # it trips the guard, `ticket_threads_count` included, unless the line is dated
  # history. Deliberate: the deleted validation names (`ticket_thread_has_project`)
  # start the same way, and a resurrected one must not slip past a tail anchor.
  # `chatUrl` is the lane's Stimulus value and nothing else: word-bounded, so a
  # future `assistantChatUrl` is not this guard's business.
  def remnant
    %r{ticket[-_ ]chat(?!_plan)|(?<![a-z_])ticket[-_ ]thread|Tickets::Chat|tickets/chat|TicketChat|
       chats\.ticket_id|select_ticket_chat|shared_thread_hint|ticket_system_prompt|ticket-row-chat-url|
       \bchatUrl(Value)?\b}ix
  end

  # Where the comment starts on this line, or nil when the line is code throughout.
  # Markdown is prose from column 0; Ruby's `#{` is interpolation, not a comment.
  # Block comments (/* */, <%# %>, <!-- -->) count on the line that opens them or
  # on a ` * ` continuation: dated history in a block belongs on such a line, or
  # a reader scanning for the date will not see it either.
  def comment_start(path, line)
    case File.extname(path)
    when '.md' then 0
    when '.rb', '.rake', '.yml', '.yaml' then line.index(/#(?!\{)/)
    when '.erb', '.html' then line.index(/<%#|<!--/)
    when '.js', '.css' then line.index(%r{//|/\*|^\s*\*})
    end
  end

  # History is allowed, undated history is not, and only IN A COMMENT: a line that
  # names the surface may stay when it also names the cut that removed it (S4-T1)
  # and the name sits in the comment part. `chat.ticket_chat? # S4-T1` is code
  # that names the surface; the trailing date does not turn it into history.
  def offender?(path, line)
    match = line.match(remnant)
    return false unless match

    start = comment_start(path, line)
    return true if start.nil? || match.begin(0) < start

    !line.include?('S4-T1')
  end

  # Text sources only: app/ also holds fonts and images, and a regex over binary
  # bytes is not a scan of the code.
  def text_source?(path)
    %w[.rb .erb .js .yml .yaml .rake .md .css .json .html].include?(File.extname(path))
  end

  def relative_files(globs)
    globs.flat_map { |glob| Dir.glob(Rails.root.join(glob)) }
         .select { |path| File.file?(path) }
         .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
  end

  def lines_where(globs)
    relative_files(globs).select { |path| text_source?(path) }.flat_map do |path|
      Rails.root.join(path).each_line.with_index(1).filter_map do |line, number|
        "#{path}:#{number}: #{line.strip}" if yield(path, line)
      end
    end
  end

  it 'has no ticket-chat vocabulary left in app/, lib/ and config/' do
    offenders = lines_where(%w[app/**/* lib/**/* config/**/*]) { |path, line| offender?(path, line) }

    expect(offenders).to be_empty, "ticket-chat remnants:\n#{offenders.join("\n")}"
  end

  # The word grep cannot see the hash-key form a remnant took once already
  # (`Chats::OwnerBackfill` filtered on `ticket_id: nil` and fell over at runtime,
  # not in a spec), so the chat-owning files get a stricter net on top: no
  # `ticket_id` at all on the chat side, no `.chats` on the ticket side. Citations
  # are the deliberate exception (a post citation carries its ticket's id), which
  # is why the chat components are not on the list.
  def chat_side
    %w[
      app/models/chat.rb app/models/chatpost.rb app/models/concerns/personal_chat_erasure.rb
      app/services/chats/**/*.rb app/services/actors/*chat*.rb app/jobs/chat_response_job.rb
      app/policies/chat_policy.rb app/controllers/organisations/*chat*_controller.rb lib/tasks/chats.rake
    ]
  end

  def ticket_side
    %w[app/models/ticket.rb app/services/actors/*ticket*.rb]
  end

  it 'names ticket_id nowhere on the chat side and .chats nowhere on the ticket side' do
    offenders = lines_where(chat_side) { |_path, line| line.match?(/\bticket_id\b/) } +
                lines_where(ticket_side) { |_path, line| line.match?(/\.chats\b/) }

    expect(offenders).to be_empty, "hash-key remnants:\n#{offenders.join("\n")}"
  end

  # S4-T2 (§7.3) put a ticket back onto the chats table, and the guard has to
  # tell the two apart instead of banning the word: `scope_ticket_id` was a
  # REFERENCE (optional, nullifying, resolved per question against the asker's
  # reach), `ticket_id` was OWNERSHIP -- a chat that belonged to a ticket and
  # rendered on its page. Since the Bezugs-Sammlung (S1) the reference lives in
  # the jsonb list `scope_references`, and `scope_ticket_id` is an IGNORED
  # rollback stub (Chat.ignored_columns, copied out by chats:backfill_scope_references)
  # that the follow-up PR drops -- shrinking this enumeration on purpose, together
  # with its entry in Lalabase::DataBackfills::TASKS. So the columns
  # and the foreign keys are ENUMERATED here. The blanket "no ticket anywhere"
  # would have had to be deleted to let T2 land, and deleting it is exactly how
  # the old coupling walks back in.
  it 'carries the ticket REFERENCE on chats and nothing of the old ownership' do
    schema = Rails.root.join('db/schema.rb').read
    chats_block = schema[/create_table "chats".*?^  end$/m]

    expect(Chat.column_names).not_to include('ticket_id')
    expect(Chat.reflect_on_association(:ticket)).to be_nil
    expect(Ticket.reflect_on_association(:chats)).to be_nil
    expect(chats_block.scan(/\w*ticket\w*/).uniq)
      .to match_array(%w[scope_ticket_id index_chats_on_scope_ticket_id])
    expect(schema.scan(/add_foreign_key "chats", "tickets".*/))
      .to eq(['add_foreign_key "chats", "tickets", column: "scope_ticket_id", on_delete: :nullify'])
  end

  it 'routes no ticket chat' do
    names = Rails.application.routes.routes.map(&:name).compact

    expect(names.grep(/ticket_chat/)).to be_empty
  end
end
