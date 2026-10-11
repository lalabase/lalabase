# frozen_string_literal: true

require 'rails_helper'

# get_ticket pages its comments and attachments and hands out full text on
# request (terminal client plan, S1 b and c). One readable relation
# (ticket.posts.readable_by) yields the entries, the total and the pages:
# visibility first, then order, then the page. posts_total never counts a
# comment the reader may not see, so a private comment cannot be inferred from
# a gap. A single comment by post_id comes out of the same relation, after the
# ticket itself was resolved and authorised: a hidden comment answers like a
# missing one.
RSpec.describe Lalabase::Tools::GetTicket, 'paging and full text', :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  def member(role_for = role, tickets: true)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role_for, active: true)
    create(:project_permission, user: user, project: project, tickets_access: 'read_only') if tickets
    user
  end

  let(:author) { member }
  let(:addressee) { member }
  let(:other) { member }
  let(:admin) { member(admin_role, tickets: false) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: author) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def run(user, **args)
    context = Lalabase::Tools::Context.new(actor: user, organisation: organisation, project: project)
    described_class.execute(args: { ticket_id: ticket.id }.merge(args), context: context)
  end

  def body(user, **args)
    JSON.parse(run(user, **args).content)
  end

  # Five public comments and two private ones for the addressee, in a fixed order.
  let!(:posts) do
    Prosopite.pause do
      base = 2.hours.ago
      Array.new(7) do |i|
        private_one = [2, 5].include?(i)
        create(:post, ticket: ticket, organisation: organisation, user: author, content: "Kommentar #{i}",
                      is_private: private_one, visible_to_user: (addressee if private_one),
                      create_embeddings: false, created_at: base + i.minutes)
      end
    end
  end

  def contents(answer) = answer['posts'].map { |post| post['body_text'] }

  describe 'pages of comments' do
    # One example per reader: Prosopite watches each call on its own.
    { other: [5, %w[0 1 3]], addressee: [7, %w[0 1 2]], author: [7, %w[0 1 2]],
      admin: [7, %w[0 1 2]] }.each do |reader, (total, first_page)|
      it "counts and pages only what the #{reader} may read" do
        answer = body(public_send(reader), posts_per_page: 3)
        expect(answer['posts_total']).to eq(total)
        expect(answer['posts_pages']).to eq((total + 2) / 3)
        expect(contents(answer)).to eq(first_page.map { |n| "Kommentar #{n}" })
      end
    end

    it 'turns the pages without skipping or repeating a readable comment' do
      first = contents(body(other, posts_per_page: 3, posts_page: 1))
      second = contents(body(other, posts_per_page: 3, posts_page: 2))
      expect(first + second).to eq(%w[0 1 3 4 6].map { |n| "Kommentar #{n}" })
    end

    # Comments of the same second are ordered by id, so a page boundary between
    # them neither skips nor repeats one. Inserted against the id order on purpose:
    # without the second key the database answers in its own order.
    # Both directions: a fixed `id: :asc` (or :desc) passes one of them. The tie
    # sits at the front of the chosen order (after every other comment for
    # newest, before them for oldest), so the first two pages hold exactly it.
    { 'newest' => [1, :reverse], 'oldest' => [3, :itself] }.each do |order, (hours_ago, arrange)|
      it "breaks a tie of created_at by id, #{order} first" do
        at = hours_ago.hours.ago.change(usec: 0)
        tied = Prosopite.pause do
          %w[d c b a].map do |last|
            create(:post, id: "00000000-0000-4000-8000-00000000000#{last}", ticket: ticket,
                          organisation: organisation, user: author, content: "Gleichzeitig #{last}",
                          create_embeddings: false, created_at: at)
          end
        end
        first = body(other, posts_per_page: 2, posts_order: order, posts_page: 1)['posts'].pluck('id')
        second = body(other, posts_per_page: 2, posts_order: order, posts_page: 2)['posts'].pluck('id')
        expect(first + second).to eq(tied.map(&:id).sort.public_send(arrange))
      end
    end

    it 'reads newest first on request' do
      answer = body(other, posts_per_page: 2, posts_order: 'newest')
      expect(contents(answer)).to eq(['Kommentar 6', 'Kommentar 4'])
      expect(answer['posts_order']).to eq('newest')
    end

    it 'keeps the old answer without paging arguments: oldest first, page 1' do
      answer = body(other)
      expect(contents(answer)).to eq(%w[0 1 3 4 6].map { |n| "Kommentar #{n}" })
      expect(answer).to include('posts_page' => 1, 'posts_order' => 'oldest', 'posts_truncated' => false)
    end

    it 'says that a page is a part' do
      expect(body(other, posts_per_page: 2)['posts_truncated']).to be(true)
    end

    it 'takes the last page there may be and a page of one' do
      max = described_class::MAX_PAGE
      expect(body(other, posts_page: max)).to include('posts' => [], 'posts_page' => max)
      expect(body(other, attachments_page: max)).to include('attachments' => [], 'attachments_page' => max)
      expect(contents(body(other, posts_per_page: 1))).to eq(['Kommentar 0'])
    end

    # The citation carries the ids of exactly the comments handed out: a later
    # save rechecks those records (Lalabase::Tools::Base, AnalysisSources), and a
    # comment missing from it would escape that check.
    it 'cites exactly the comments of the page' do
      result = run(addressee, posts_per_page: 3, posts_page: 1)
      handed_out = JSON.parse(result.content)['posts'].pluck('id')
      expect(handed_out).to eq(posts.first(3).map(&:id))
      expect(result.citations.sole[:post_ids]).to eq(handed_out)
    end

    it 'caps posts_per_page at the old list bound' do
      expect(body(other, posts_per_page: 500)['posts_per_page']).to eq(described_class::MAX_POSTS)
    end

    it 'refuses arguments it cannot use' do
      max = described_class::MAX_PAGE
      [{ posts_page: 'zwei' }, { posts_page: 0 }, { posts_page: max + 1 }, { posts_order: 'random' },
       { posts_per_page: 'x' }, { posts_per_page: 0 }, { posts_per_page: -1 }, { attachments_page: -1 },
       { attachments_page: max + 1 }, { post_id: 'oops' }, { full_text: 'true' }, { full_text: 1 },
       { full_text: 'yes' }].each do |args|
        result = run(other, **args)
        expect(result.error).to be_present, args.inspect
        expect(result.code).to eq(:invalid_input), args.inspect
      end
    end
  end

  describe 'pages of attachments' do
    before do
      Prosopite.pause do
        base = 1.hour.ago
        (described_class::MAX_ATTACHMENTS + 3).times do |i|
          create(:ticket_document, :with_pdf, ticket: ticket, organisation: organisation,
                                              plain_text_version: "file-#{i}", created_at: base + i.minutes)
        end
      end
    end

    it 'pages them oldest first, with the total and the page count' do
      second = body(other, attachments_page: 2)
      expect(second['attachments'].map { |file| file['text'] }).to eq(%w[file-10 file-11 file-12])
      expect(second).to include('attachments_total' => 13, 'attachments_page' => 2, 'attachments_pages' => 2)
    end
  end

  # More than a page of attachments from the same second: ordered by id, so the
  # page boundary neither skips nor repeats one. Inserted against the id order.
  describe 'attachments of the same second' do
    let!(:files) do
      Prosopite.pause do
        at = 1.hour.ago.change(usec: 0)
        (described_class::MAX_ATTACHMENTS + 2).times.map do |i|
          create(:ticket_document, :with_pdf, id: format('00000000-0000-4000-8000-%012d', 99 - i), ticket: ticket,
                                              organisation: organisation, created_at: at)
        end
      end
    end

    it 'pages them by id' do
      first = body(other, attachments_page: 1)['attachments'].pluck('id')
      second = body(other, attachments_page: 2)['attachments'].pluck('id')
      expect(first + second).to eq(files.map(&:id).sort)
    end
  end

  describe 'full text' do
    let(:long) { 'a' * (described_class::MAX_BODY_CHARS + 500) }

    it 'hands out the whole description on request, and only then' do
      ticket.update!(content: long)
      expect(body(other)['description_text']).to end_with(described_class::TRUNCATION_MARKER)
      expect(body(other, full_text: true)['description_text']).to eq(long)
    end

    it 'bounds even the full text' do
      ticket.update!(content: 'b' * (described_class::MAX_FULL_TEXT_CHARS + 10))
      answer = body(other, full_text: true)
      bound = described_class::MAX_FULL_TEXT_CHARS + described_class::TRUNCATION_MARKER.length
      expect(answer['description_text'].length).to eq(bound)
      expect(answer['description_html']).to end_with(described_class::TRUNCATION_MARKER)
      expect(answer['description_html'].length).to be <= bound
    end

    # One example per value: Prosopite watches each call on its own.
    [false, nil, ''].each do |value|
      it "keeps the cut for full_text #{value.inspect}" do
        ticket.update!(content: long)
        expect(body(other, full_text: value)['description_text']).to end_with(described_class::TRUNCATION_MARKER)
      end
    end
  end

  describe 'one comment by post_id' do
    let(:long_post) do
      Prosopite.pause do
        create(:post, ticket: ticket, organisation: organisation, user: author, content: long_text,
                      create_embeddings: false)
      end
    end
    let(:long_text) { 'c' * (described_class::MAX_BODY_CHARS + 300) }
    let(:private_post) { posts[2] }

    it 'returns that comment whole' do
      answer = body(other, post_id: long_post.id)
      expect(answer['posts'].map { |post| post['id'] }).to eq([long_post.id])
      expect(answer['posts'].first['body_text']).to eq(long_text)
    end

    it 'answers a hidden private comment exactly like a missing one' do
      hidden = run(other, post_id: private_post.id)
      missing_id = SecureRandom.uuid
      missing = run(other, post_id: missing_id)
      expect(hidden.empty?).to be true
      expect(hidden.content.sub(private_post.id, 'ID')).to eq(missing.content.sub(missing_id, 'ID'))
      expect(hidden.content).not_to include('Kommentar 2')
    end

    # The count beside the one comment is the reader's count as well: a total of
    # every comment would reveal the private ones by the gap.
    { other: 5, addressee: 7, author: 7, admin: 7 }.each do |reader, total|
      it "counts beside one comment only what the #{reader} may read" do
        answer = body(public_send(reader), post_id: posts[0].id)
        expect(answer).to include('posts_total' => total, 'posts_truncated' => true, 'post_id' => posts[0].id)
      end
    end

    it 'cites the one comment it hands out' do
      expect(run(addressee, post_id: private_post.id).citations.sole[:post_ids]).to eq([private_post.id])
    end

    it 'bounds even one comment, in both of its texts' do
      huge = Prosopite.pause do
        create(:post, ticket: ticket, organisation: organisation, user: author, create_embeddings: false,
                      content: 'd' * (described_class::MAX_FULL_TEXT_CHARS + 10))
      end
      post = body(other, post_id: huge.id)['posts'].first
      marker = described_class::TRUNCATION_MARKER
      expect(post['body_text'].length).to eq(described_class::MAX_FULL_TEXT_CHARS + marker.length)
      expect(post['body_html']).to end_with(marker)
      expect(post['body_html'].length).to be <= described_class::MAX_FULL_TEXT_CHARS + marker.length
    end

    %i[author addressee admin].each do |reader|
      it "lets the #{reader} read the private comment" do
        expect(body(public_send(reader), post_id: private_post.id)['posts'].first['body_text']).to eq('Kommentar 2')
      end
    end

    it 'does not reach a comment of another ticket through this one' do
      other_ticket = create(:ticket, project: project, organisation: organisation, creator: author)
      foreign = Prosopite.pause do
        create(:post, ticket: other_ticket, organisation: organisation, user: author, content: 'Woanders',
                      create_embeddings: false)
      end
      expect(run(other, post_id: foreign.id).empty?).to be true
    end

    it 'resolves the ticket first: a hidden ticket answers like a missing one, comment or not' do
      outsider = member(tickets: false)
      expect(run(outsider, post_id: long_post.id).content).to eq("No ticket found for #{ticket.id}.")
    end

    # The scope above stops an outsider before serve; this one gets through the
    # scope and is refused by the policy itself. Not a single comment may be read
    # before that refusal.
    it 'authorises the ticket before it reads a comment' do
      long_post
      allow(TicketPolicy).to receive(:new).and_wrap_original do |original, *policy_args|
        original.call(*policy_args).tap { |policy| allow(policy).to receive(:show?).and_return(false) }
      end
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        statements << payload[:sql]
      end
      begin
        expect { run(other, post_id: long_post.id) }.to raise_error(Pundit::NotAuthorizedError)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
      expect(statements.grep(/FROM "posts"/)).to be_empty
    end
  end
end
