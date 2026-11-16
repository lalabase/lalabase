# frozen_string_literal: true

require 'rails_helper'

# What:  ObjectLinks::Chips.apply and .prefetch, and the request memo behind them
#        (ObjectLinks::Targets through Current).
# Type:  Service spec that counts SQL queries.
# Why:   A timeline renders many comments, each through the ActionText layout. Targets are
#        loaded together per rich text (one query per type), remembered for the request,
#        and a list can load the targets of all its texts at once (.prefetch). A text
#        without an address of the organisation costs nothing at all.
RSpec.describe ObjectLinks::Chips do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:reader) { create(:user) }
  let(:hosts) { ['www.example.com'] }
  let(:tickets) { create_list(:ticket, 5, project: project, organisation: organisation) }
  let(:meetings) { create_list(:meeting, 3, project: project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause do
      create(:membership, user: reader, organisation: organisation)
      create(:project_permission, user: reader, project: project, tickets_access: :read_write,
                                  meetings_access: :read_only)
      tickets
      meetings
    end
    Current.reset
  end

  after do
    Current.reset
    ActsAsTenant.current_tenant = nil
  end

  def address(record)
    base = "http://www.example.com/org/#{organisation.id}/projects/#{project.id}"
    record.is_a?(Ticket) ? "#{base}/tickets/#{record.id}" : "#{base}/meetings/#{record.id}"
  end

  def html_for(records)
    records.map { |record| %(<a href="#{address(record)}">#{address(record)}</a>) }.join(' ')
  end

  # A fresh user object each time: User memoizes its role and permissions per instance, and
  # a count must not depend on what an earlier example already read through it.
  def apply(html, viewer: reader)
    described_class.apply(html: html, viewer: viewer, organisation: organisation, hosts: hosts)
  end

  # The reader's reach for one type (membership, role, permissions, project permissions)
  # and one load of the targets: what one type may cost, however many links name it.
  let(:queries_per_type) { 6 }

  def queries_during(&)
    count = 0
    counter = lambda do |*, payload|
      count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end

  it 'costs no query for a text without an address of the organisation' do
    html = '<div>Plain text with <a href="https://elsewhere.example.org/x">a link</a></div>'

    expect(queries_during { expect(apply(html)).to eq(html) }).to eq(0)
  end

  it 'loads eight links of two types in a bounded number of queries, and nothing the second time' do
    html = html_for(tickets + meetings)

    first = queries_during { expect(apply(html).scan('object-chip--').size).to eq(8) }
    second = queries_during { apply(html) }

    expect(first).to be <= 2 * queries_per_type
    expect(second).to eq(0)
  end

  %i[uppercase undashed].each do |spelling|
    it "prefetches addresses with an #{spelling} organisation UUID" do
      org_id = spelling == :uppercase ? organisation.id.upcase : organisation.id.delete('-')
      html = html_for(tickets).gsub(organisation.id, org_id)
      described_class.prefetch(htmls: [html], viewer: reader, organisation: organisation, hosts: hosts)

      expect(queries_during { expect(apply(html).scan('object-chip--').size).to eq(5) }).to eq(0)
    end
  end

  it "resolves the reader's reach once per type, so a second text pays only its load" do
    apply(html_for(tickets.first(1)))

    expect(queries_during { apply(html_for([tickets.last])) }).to eq(1)
  end

  it 'costs the same for one link as for five of a type' do
    one = queries_during { apply(html_for(tickets.first(1)), viewer: User.find(reader.id)) }
    Current.reset
    five = queries_during { apply(html_for(tickets), viewer: User.find(reader.id)) }

    expect(five).to eq(one)
  end

  it 'loads the targets of many texts at once with .prefetch' do
    texts = (tickets + meetings).map { |record| html_for([record]) }
    described_class.prefetch(htmls: texts, viewer: reader, organisation: organisation, hosts: hosts)

    expect(queries_during { texts.each { |text| apply(text) } }).to eq(0)
  end

  it 'leaves the markup around a chip as it was' do
    html = %(<div><strong>Look</strong> at #{html_for(tickets.first(1))}, <code>x &lt; y</code></div>)

    result = Nokogiri::HTML5.fragment(apply(html))

    expect(result.at_css('strong').text).to eq('Look')
    expect(result.at_css('code').text).to eq('x < y')
    expect(result.at_css('a.object-chip')).to be_present
  end

  it 'answers an html_safe string' do
    expect(apply(html_for(tickets.first(1)))).to be_html_safe
  end
end
