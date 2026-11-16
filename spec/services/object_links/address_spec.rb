# frozen_string_literal: true

require 'rails_helper'

# What:  ObjectLinks::Address.parse, which reads a link's address and names the object it
#        points at (type and id), or nothing.
# Type:  Service spec, no database.
# Why:   An address names an object in two forms, its page and the lane parameter of an
#        overview. Only this instance's hosts and only the current organisation count, so a
#        foreign host or another organisation stays a plain link however the path looks.
RSpec.describe ObjectLinks::Address do
  let(:org_id) { '11111111-2222-4333-8444-555555555555' }
  let(:project_id) { '22222222-3333-4444-8555-666666666666' }
  let(:object_id_value) { '33333333-4444-4555-8666-777777777777' }
  let(:hosts) { ['app.example.com', /.*\.example\.net/] }

  def parse(href)
    described_class.parse(href, organisation_id: org_id, hosts: hosts)
  end

  def base
    "https://app.example.com/org/#{org_id}"
  end

  describe 'the page of an object' do
    {
      'ticket' => ['projects/%<p>s/tickets/%<id>s', :ticket],
      'meeting' => ['projects/%<p>s/meetings/%<id>s', :meeting],
      'note' => ['projects/%<p>s/notes/%<id>s', :note],
      'document' => ['projects/%<p>s/documents/%<id>s', :document]
    }.each do |name, (path, type)|
      it "reads a #{name} with its project" do
        ref = parse("#{base}/#{format(path, p: project_id, id: object_id_value)}")

        expect(ref).to eq(described_class::Ref.new(type: type, id: object_id_value, project_id: project_id))
      end
    end

    it 'reads a person' do
      expect(parse("#{base}/people/#{object_id_value}"))
        .to eq(described_class::Ref.new(type: :person, id: object_id_value, project_id: nil))
    end

    it 'reads a member by the account' do
      expect(parse("#{base}/people/members/#{object_id_value}"))
        .to eq(described_class::Ref.new(type: :member, id: object_id_value, project_id: nil))
    end
  end

  describe 'the lane parameter of an overview' do
    it 'reads ?ticket_id= on the ticket list' do
      expect(parse("#{base}/projects/#{project_id}/tickets?ticket_id=#{object_id_value}"))
        .to eq(described_class::Ref.new(type: :ticket, id: object_id_value, project_id: project_id))
    end

    it 'reads ?meeting_id= on the overview of all meetings, without a project' do
      expect(parse("#{base}/meetings?meeting_id=#{object_id_value}"))
        .to eq(described_class::Ref.new(type: :meeting, id: object_id_value, project_id: nil))
    end

    it "reads ?meeting_id= on a project's meetings" do
      expect(parse("#{base}/projects/#{project_id}/meetings?meeting_id=#{object_id_value}"))
        .to eq(described_class::Ref.new(type: :meeting, id: object_id_value, project_id: project_id))
    end

    it 'reads ?person_id= and ?member_id= on the people page' do
      expect(parse("#{base}/people?person_id=#{object_id_value}").type).to eq(:person)
      expect(parse("#{base}/people?member_id=#{object_id_value}").type).to eq(:member)
    end

    it 'reads ?note_id= on the notes and on the knowledge page, ?document_id= on the knowledge page' do
      expect(parse("#{base}/projects/#{project_id}/notes?note_id=#{object_id_value}").type).to eq(:note)
      expect(parse("#{base}/projects/#{project_id}/knowledge?note_id=#{object_id_value}&type=all").type).to eq(:note)
      expect(parse("#{base}/projects/#{project_id}/knowledge?document_id=#{object_id_value}").type).to eq(:document)
    end

    it 'reads an id written without dashes as the same object' do
      ref = parse("#{base}/meetings?meeting_id=#{object_id_value.delete('-')}")

      expect(ref.id).to eq(object_id_value)
    end

    it 'names nothing for an overview without a selection' do
      expect(parse("#{base}/meetings")).to be_nil
      expect(parse("#{base}/projects/#{project_id}/tickets?status=open")).to be_nil
    end
  end

  describe 'what stays a plain link' do
    it 'a foreign host' do
      expect(parse("https://elsewhere.example.org/org/#{org_id}/people/#{object_id_value}")).to be_nil
    end

    it 'a host that only contains an own host' do
      expect(parse("https://app.example.com.elsewhere.example.org/org/#{org_id}/people/#{object_id_value}")).to be_nil
      expect(parse("https://a.example.net.elsewhere.example.org/org/#{org_id}/people/#{object_id_value}")).to be_nil
    end

    it 'a host matching a pattern of the instance counts' do
      expect(parse("https://a.example.net/org/#{org_id}/people/#{object_id_value}")).to be_present
    end

    it 'another organisation' do
      other = '99999999-2222-4333-8444-555555555555'

      expect(parse("https://app.example.com/org/#{other}/people/#{object_id_value}")).to be_nil
    end

    it 'an address with credentials, another scheme or a format' do
      expect(parse("https://user:secret@app.example.com/org/#{org_id}/people/#{object_id_value}")).to be_nil
      expect(parse("ftp://app.example.com/org/#{org_id}/people/#{object_id_value}")).to be_nil
      expect(parse("#{base}/projects/#{project_id}/tickets/#{object_id_value}.json")).to be_nil
    end

    it 'an id that is no uuid, a page that is no object and an unknown path' do
      expect(parse("#{base}/projects/#{project_id}/tickets/42")).to be_nil
      expect(parse("#{base}/projects/#{project_id}/tickets/#{object_id_value}/edit")).to be_nil
      expect(parse("#{base}/people/new")).to be_nil
      expect(parse("#{base}/nowhere/#{object_id_value}")).to be_nil
    end

    it 'something that is no address' do
      expect(parse(nil)).to be_nil
      expect(parse('')).to be_nil
      expect(parse('javascript:alert(1)')).to be_nil
      expect(parse('https://app.example.com/org/ bad')).to be_nil
    end
  end

  it 'reads a path without a host as an address of this instance' do
    expect(parse("/org/#{org_id}/people/#{object_id_value}").type).to eq(:person)
  end
end
