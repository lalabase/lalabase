# frozen_string_literal: true

require 'rails_helper'

# doc/projekt_chat_abbau_plan.md step 1: the per-project chat (`/projects/:id/chats`,
# the sidebar entry labelled "GPT") is dismantled in favour of the org-wide personal
# assistant, and this is the invariant that keeps it dismantled. It is the third cut
# of the same shape -- the ticket chat went first (S4-T1), and its guard is the
# template here, including the reason for the template: a remnant that slips back in
# (a merge from an old branch, a helper resurrected out of habit) renders fine and
# throws nothing, it just re-opens a surface the plan closed.
#
# The scan runs over app/, lib/ and config/ WHOLESALE, not over the list of files the
# plan happens to name. The list is the shape of the problem: Rev. 2 of the assistant
# plan named four things to remove and the inventory found thirty, and this plan's
# own inventory misses the public feature page and the privacy statement, both of
# which this scan finds.
#
# Red on purpose until step 3 is done. `spec/architecture/` is a DIRECTORY entry in
# .github/workflows/guards.yml, so this file runs in CI from the moment it lands: the
# branch is red until the surface is gone, which is the signal, not an accident.
RSpec.describe 'No project-chat remnants', type: :model do
  # Code vocabulary AND prose, German and English: a stale comment that still explains
  # the code by a surface that no longer exists is a remnant too. `proje(c|k)t chat`
  # covers "project chat", "project-chat", "project_chat", "Projekt-Chat".
  #
  # `_abbau` is the negative lookahead for this cut's own marker (see #offender?),
  # exactly as `(?!_plan)` was for the ticket chat's design document: the word that
  # licences a line of history must not itself be an offence.
  #
  # `ChatsController` / `ChatpostsController` carry a LEADING word boundary only, so
  # `AssistantChatsController` and `AssistantChatpostsController` -- the surface that
  # stays -- do not match. `project_threads` is the Chat scope that separated the two
  # kinds; with one kind left it has nothing to separate.
  def remnant
    /proje(c|k)t[-_ ]chat(?!_abbau)|\bChatsController\b|\bChatpostsController\b|
     \bSessionListComponent\b|navigation\.gpt|\bproject_threads\b/ix
  end

  # Step 4 of the plan renames `project_chat_enabled` to the thing it actually gates.
  # RELEASE 1 of that rename has landed: the admin toggle, its labels, its flash keys
  # and its route are called code_indexing now, and the only vocabulary left is the
  # COLUMN itself -- read as the second half of an OR in CodeIndexingGated, written by
  # the toggle, copied by organisations:backfill_code_indexing.
  #
  # The carve-out shrank accordingly, and it shrinks again to nothing in release 3.
  # Enumerated rather than folded into #remnant as a lookahead, so it stays readable
  # and can be deleted in one piece -- and pinned by the last example below, which goes
  # red the day the column is dropped. Without the pin the exception outlives its
  # reason and quietly covers a genuine remnant spelled the same way.
  def step_four_vocabulary
    /project_chat_enabled/
  end

  # Where the comment starts on this line, or nil when the line is code throughout.
  # Markdown is prose from column 0; Ruby's `#{` is interpolation, not a comment.
  def comment_start(path, line)
    case File.extname(path)
    when '.md' then 0
    when '.rb', '.rake', '.yml', '.yaml' then line.index(/#(?!\{)/)
    when '.erb', '.html' then line.index(/<%#|<!--/)
    when '.js', '.css' then line.index(%r{//|/\*|^\s*\*})
    end
  end

  # An ADDRESS is not a remnant. /de/funktionen/projekt-chat, its English twin and
  # guides/features/project-chat are where bookmarks, the sitemap and the in-app
  # help links point. The PAGE behind them is rewritten to describe the KI-Assistent;
  # the door is not moved, because moving it needs redirects this app does not have,
  # and CLAUDE.md is explicit that an address is not a translation.
  #
  # Narrow on purpose: an address is lowercase, hyphenated, and sits directly behind
  # a path separator or a quote. "Projekt-Chat" in prose is capitalised and does not
  # qualify, which is exactly the difference between an address and a promise. So
  # `[KI-Projekt-Chat](../features/project-chat)` still trips on its LINK TEXT while
  # the target is left alone -- which is why every match on a line is examined, not
  # just the first one.
  def address?(line, match)
    text = match[0]
    return false unless text.include?('-') && text == text.downcase

    before = match.begin(0).positive? ? line[match.begin(0) - 1] : nil
    ['/', "'", '"'].include?(before)
  end

  # History is allowed, undated history is not, and only IN A COMMENT: a line may name
  # the surface when it also names the cut that removed it (`projekt_chat_abbau`, the
  # stem of the plan document, so the marker is also the way to find it) and the name
  # sits in the comment part. `chat.project_id # projekt_chat_abbau` is code that
  # names the surface; a trailing marker does not turn it into history.
  def offender?(path, line)
    return false if line.match?(step_four_vocabulary)

    start = comment_start(path, line)
    historical = line.include?('projekt_chat_abbau')

    line.to_enum(:scan, remnant).map { Regexp.last_match }.any? do |match|
      next false if address?(line, match)
      next true if start.nil? || match.begin(0) < start

      !historical
    end
  end

  # Text sources only: app/ also holds fonts and images, and a regex over binary bytes
  # is not a scan of the code.
  def text_source?(path)
    %w[.rb .erb .js .yml .yaml .rake .md .css .json .html].include?(File.extname(path))
  end

  # app/changelog/ is excluded permanently: those files announce a release on a date
  # and are history by construction, the same allowance the ticket-chat guard made for
  # the design document it was named after. Rewriting a shipped announcement would be
  # a lie about what happened in June.
  def scanned?(path)
    text_source?(path) && !path.start_with?('app/changelog/')
  end

  def relative_files(globs)
    globs.flat_map { |glob| Dir.glob(Rails.root.join(glob)) }
         .select { |path| File.file?(path) }
         .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
  end

  def lines_where(globs)
    relative_files(globs).select { |path| scanned?(path) }.flat_map do |path|
      Rails.root.join(path).each_line.with_index(1).filter_map do |line, number|
        "#{path}:#{number}: #{line.strip}" if yield(path, line)
      end
    end
  end

  it 'has no project-chat vocabulary left in app/, lib/ and config/' do
    offenders = lines_where(%w[app/**/* lib/**/* config/**/*]) { |path, line| offender?(path, line) }

    expect(offenders).to be_empty, "project-chat remnants:\n#{offenders.join("\n")}"
  end

  # The word grep cannot see these: the four automatic retrieval layers of the
  # single-project path carry no "project chat" in their names, and they lose their
  # ONLY caller with the surface (`#call`'s non-org branch). Left behind they are
  # dead code that reads like a feature -- and the plan's accepted loss ("the project
  # chat gets code context without asking for it") would be unaccounted for.
  # `#org_call` and the content layer stay: that is the assistant's path.
  it 'keeps only the org path of the project RAG retriever' do
    retriever = Lalabase::ProjectRag::Retriever
    methods = retriever.private_instance_methods(false) + retriever.instance_methods(false)

    expect(methods).to include(:org_call, :fetch_org_content)
    expect(methods).not_to include(:fetch_vision, :fetch_capabilities, :fetch_symbols)
  end

  it 'routes no project chat' do
    names = Rails.application.routes.routes.map(&:name).compact

    # toggle_project_chat_admin_organisation is the step-4 flag toggle, not the surface.
    expect(names.grep(/project_chat/).grep_v(/\Atoggle_project_chat_admin/)).to be_empty
  end

  # Mirror of the ticket-chat guard's schema example, and the same split: the
  # ASSOCIATIONS go with the surface in step 3, the COLUMN goes one release later in
  # step 5 (a dropped column against running old code is a 500 window). So `project_id`
  # is asserted PRESENT here -- when step 5 drops it, this line is what has to change,
  # deliberately, rather than a blanket "no project anywhere" quietly covering both.
  it 'owns no chats from the project side, and still carries the column step 5 drops' do
    expect(Project.reflect_on_association(:chats)).to be_nil
    expect(Chat.reflect_on_association(:project)).to be_nil
    expect(Chat.column_names).to include('project_id')
  end

  it 'has no project-chat controllers, views or session list left' do
    remaining = %w[
      app/controllers/organisations/chats_controller.rb
      app/controllers/organisations/chatposts_controller.rb
      app/views/organisations/chats
      app/views/organisations/chatposts
      app/components/neo/chat/session_list_component.rb
      app/components/neo/chat/session_list_component.html.erb
    ].select { |path| File.exist?(Rails.root.join(path)) }

    expect(remaining).to be_empty, "project-chat files still present:\n#{remaining.join("\n")}"
  end

  # The plan's own trap: `by_name` and `all_schemas` both DEFAULT to `set: :project_chat`,
  # so removing the set without touching the defaults leaves every caller that omits the
  # argument raising ArgumentError at runtime and nowhere in a spec. Pinning the two
  # remaining sets and the raise is what makes that a red example instead of a 500.
  it 'offers only the two assistant tool sets' do
    expect(Lalabase::Tools::Registry::CHAT_SETS).to eq(%i[assistant assistant_with_code])
    expect { Lalabase::Tools::Registry.for(:project_chat) }.to raise_error(ArgumentError)
    expect(Lalabase::Tools::Registry.all_schemas).to be_an(Array)
    expect(Lalabase::Tools::Registry.by_name('list_tickets')).to eq(Lalabase::Tools::ListTickets)
  end

  it 'has no GPT navigation entry in either locale' do
    labels = %i[de en].index_with { |locale| I18n.t('navigation.gpt', locale: locale, default: nil) }

    expect(labels).to eq(de: nil, en: nil)
  end

  # The pin for #step_four_vocabulary, and the shape of release 2 in one example: the
  # old column is gone from BOTH models (nothing SELECTs it, which is what makes
  # release 3's DROP safe) and still present in the DATABASE. Release 3 drops it, this
  # goes red, and the carve-out goes with it.
  #
  # Both twins, and not as decoration: Admin::Organisation is a separate class over the
  # same table, and a column ignored on one of them alone would leave the operator's
  # path answering 500 after the drop while the tenant side was fine.
  it 'ignores the old column on both models while the database still has it' do
    [Organisation, Admin::Organisation].each do |model|
      expect(model.column_names).to include('code_indexing_enabled'), model.name
      expect(model.column_names).not_to include('project_chat_enabled'), model.name
      expect(model.new).to respond_to(:code_indexing?)
    end

    expect(Organisation.connection.columns(:organisations).map(&:name))
      .to include('project_chat_enabled')
  end
end
