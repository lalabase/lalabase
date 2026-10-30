# frozen_string_literal: true

require 'rails_helper'

# Golden contract for the ticket JSON shape (D4). Pins the exact key sets so the
# extraction from Api::V1::TicketsController — and any future MCP read tool that
# shares this serializer — provably cannot drift the wire format.
RSpec.describe Tickets::Serializer do
  let(:organisation) { create(:organisation) }
  let(:viewer) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, :with_custom_attributes, project: project, organisation: organisation,
                                               creator: viewer, title: 'Export')
    end
  end

  subject(:serializer) { described_class.new(current_user: viewer) }

  describe '#summary' do
    it 'pins the summary key set and core values' do
      hash = ActsAsTenant.with_tenant(organisation) { serializer.summary(ticket) }

      expect(hash.keys).to contain_exactly(
        :id, :number, :title, :status, :status_functions, :ticket_type, :parent_id, :assignees, :creator,
        :created_at, :updated_at
      )
      expect(hash[:id]).to eq(ticket.id)
      expect(hash[:title]).to eq('Export')
      expect(hash[:status]).to eq('open') # from :with_custom_attributes
      expect(hash[:status_functions]).to eq([]) # the factory's option carries none
      expect(hash[:creator]).to eq({ id: viewer.id, name: viewer.display_name })
      expect(hash[:parent_id]).to be_nil
      expect(hash[:created_at]).to eq(ticket.created_at.iso8601)
    end
  end

  # The database hands assignees back in no fixed order; the MCP contract and
  # every client diff would flicker (the contract spec did, on a fresh database).
  it 'lists the assignees by name, then by id, whatever order they were added in' do
    people = %w[Zoe Anna Max].map { |name| create(:user, first_name: name, last_name: 'Test') }
    ActsAsTenant.with_tenant(organisation) { people.each { |person| ticket.assignees << person } }

    hash = ActsAsTenant.with_tenant(organisation) { serializer.summary(ticket.reload) }

    expect(hash[:assignees].pluck(:name)).to eq(['Anna Test', 'Max Test', 'Zoe Test'])
  end

  # What the status means in its project, so a client need not guess it from a name
  # that means something else in every project.
  describe 'status_functions' do
    before { ticket } # its factory gives the project the status select

    def give_status_functions(project, by_value)
      definition = project.ticket_attribute_definitions.find_by!(name: 'status')
      values = definition.options['allowed_values'].map do |option|
        option.merge('system_functions' => by_value.fetch(option['value'], []))
      end
      definition.update!(options: definition.options.merge('allowed_values' => values))
    end

    it "carries the status functions of the ticket's option, matched without case" do
      hash = ActsAsTenant.with_tenant(organisation) do
        give_status_functions(project, 'open' => ['is_in_progress'])
        ticket.update_columns(custom_attributes: ticket.custom_attributes.merge('status' => 'OPEN'))
        serializer.summary(ticket)
      end

      expect(hash[:status_functions]).to eq(['is_in_progress'])
    end

    it 'is empty for a ticket without a status and for a status no option has' do
      hashes = ActsAsTenant.with_tenant(organisation) do
        give_status_functions(project, 'open' => ['is_open'])
        [nil, 'archived'].map do |status|
          ticket.update_columns(custom_attributes: ticket.custom_attributes.merge('status' => status))
          serializer.summary(ticket)
        end
      end

      expect(hashes.pluck(:status_functions)).to eq([[], []])
    end

    it "reads each project's options once, however many of its tickets it serializes" do
      tickets = ActsAsTenant.with_tenant(organisation) do
        give_status_functions(project, 'open' => ['is_open'])
        ids = create_list(:ticket, 3, :with_custom_attributes, project: project, organisation: organisation).map(&:id)
        Ticket.where(id: ids).includes(:assignees, :creator).to_a
      end

      queries = []
      callback = lambda do |*, payload|
        queries << payload[:sql] if payload[:sql].include?('ticket_attribute_definitions')
      end
      functions = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        ActsAsTenant.with_tenant(organisation) { tickets.map { |t| serializer.summary(t)[:status_functions] } }
      end

      expect(functions).to eq([['is_open']] * 3)
      expect(queries.size).to eq(1)
    end
  end

  describe '#full' do
    it 'pins the full key set (summary + body/project/posts)' do
      hash = ActsAsTenant.with_tenant(organisation) { serializer.full(ticket) }

      expect(hash.keys).to contain_exactly(
        :id, :number, :title, :status, :status_functions, :ticket_type, :parent_id, :assignees, :creator,
        :created_at, :updated_at, :summary, :description_html, :description_text, :custom_attributes, :project, :posts
      )
      expect(hash[:project]).to eq({ id: project.id, name: project.name })
      expect(hash[:posts]).to eq([])
    end

    it 'pins the post key set for serialized posts' do
      hash = ActsAsTenant.with_tenant(organisation) do
        create(:post, ticket: ticket, user: viewer, is_private: false)
        serializer.full(ticket)
      end

      expect(hash[:posts].size).to eq(1)
      expect(hash[:posts].first.keys).to contain_exactly(
        :id, :author, :body_html, :body_text, :is_private, :attachments_count, :attachments, :created_at, :updated_at
      )
    end

    # What a comment says about its file: no signed URL, no extracted text. Pinned
    # with text in the column, which is what #attachments would hand on.
    it 'pins the key set of a comment file, by the id of its PostDocument' do
      document, hash = ActsAsTenant.with_tenant(organisation) do
        post = create(:post, ticket: ticket, user: viewer, is_private: false)
        made = create(:post_document, :with_pdf, post: post, organisation: organisation, plain_text_version: 'Inhalt')
        [made, serializer.full(ticket)]
      end

      expect(hash[:posts].first[:attachments]).to eq(
        [{ id: document.id, filename: 'test_document.pdf', content_type: 'application/pdf', byte_size: 25 }]
      )
    end

    # The count used to read post.attachments (has_many_attached), which NOTHING in
    # the app writes: every comment attachment is a PostDocument. So it answered 0
    # for every comment that had one, and the MCP tool passed that 0 to the model.
    it 'counts the comment attachments the app actually writes (post_documents)' do
      hash = ActsAsTenant.with_tenant(organisation) do
        post = create(:post, ticket: ticket, user: viewer, is_private: false)
        create(:post_document, post: post, organisation: organisation)
        serializer.full(ticket)
      end

      expect(hash[:posts].first[:attachments_count]).to eq(1)
    end
  end

  # The ticket's own attachments, with the text that was extracted from them at
  # upload time. Deliberately its OWN method rather than a key in #full: the HTTP
  # API renders #full on every show and builds its own attachment list with signed
  # URLs, so a body of PDF text in there would be payload nobody asked for.
  describe '#attachments' do
    def attach(trait, **attrs)
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket_document, trait, ticket: ticket, organisation: organisation, **attrs)
        serializer.attachments(ticket.reload)
      end
    end

    it 'pins the attachment key set and hands over the extracted text' do
      list = attach(:with_pdf, plain_text_version: 'Kostenschaetzung: 4.200 Euro')

      expect(list.size).to eq(1)
      expect(list.first.keys).to contain_exactly(
        :id, :filename, :content_type, :byte_size, :text, :text_status
      )
      expect(list.first[:filename]).to eq('test_document.pdf')
      expect(list.first[:content_type]).to eq('application/pdf')
      expect(list.first[:text]).to eq('Kostenschaetzung: 4.200 Euro')
      expect(list.first[:text_status]).to eq('available')
    end

    # The difference the reader needs: "there is no text in this file" is an answer,
    # "the text was never read out" is a defect on our side. Both look identical
    # without the status, and the model would fill the silence either way.
    #
    # NULL and '' are not the same silence, and the column already tells them apart:
    # ExtractPlainTextProcessingService#set_plain_text writes '' when the extractor
    # ran and found nothing, #clear_plain_text_data writes NULL when it never ran or
    # blew up. TicketDocumentProcessingJob runs perform_later, so NULL is above all
    # the state of a file uploaded a second ago.
    it 'says unavailable while a readable type has not been read out yet' do
      list = attach(:with_pdf, plain_text_version: nil)

      expect(list.first[:text]).to be_nil
      expect(list.first[:text_status]).to eq('unavailable')
    end

    it 'says empty when the extractor ran and found no text' do
      list = attach(:with_pdf, plain_text_version: '')

      expect(list.first[:text]).to be_nil
      expect(list.first[:text_status]).to eq('empty')
    end

    it 'says unsupported for a type the extractor never reads' do
      list = attach(:with_png, plain_text_version: nil)

      expect(list.first[:text_status]).to eq('unsupported')
    end

    it 'is empty for a ticket without attachments' do
      expect(ActsAsTenant.with_tenant(organisation) { serializer.attachments(ticket) }).to eq([])
    end

    # The bound belongs in the query, not behind it: without it every row's full
    # plain_text_version (a whole PDF's text) is read out of Postgres and turned into
    # a Ruby hash before the caller throws all but ten away.
    describe 'bounded by the caller' do
      # Paused for the SETUP only: every ticket_document create touches its ticket and
      # attaches its own blob, which prosopite reads as an N+1 of the factory. The block
      # form restores the previous state even if a create raises, and the read under
      # test below stays under watch.
      def attach_many(count)
        Prosopite.pause do
          ActsAsTenant.with_tenant(organisation) do
            base = 1.hour.ago
            count.times do |i|
              create(:ticket_document, :with_pdf, ticket: ticket, organisation: organisation,
                                                  plain_text_version: "file-#{i}", created_at: base + i.minutes)
            end
          end
        end
      end

      it 'reads no more rows than the limit it was given' do
        attach_many(4)

        list = ActsAsTenant.with_tenant(organisation) { serializer.attachments(ticket.reload, limit: 2) }

        expect(list.size).to eq(2)
      end

      # Which files survive the bound must not depend on the order the database felt
      # like: the oldest ones do, the same way the posts are oldest first.
      it 'keeps the oldest files, not whichever the database returns first' do
        attach_many(4)

        list = ActsAsTenant.with_tenant(organisation) { serializer.attachments(ticket.reload, limit: 2) }

        expect(list.map { |file| file[:text] }).to eq(%w[file-0 file-1])
      end

      it 'counts every attachment, including the ones beyond the limit' do
        attach_many(4)

        expect(ActsAsTenant.with_tenant(organisation) { serializer.attachments_total(ticket.reload) }).to eq(4)
      end
    end
  end
end
