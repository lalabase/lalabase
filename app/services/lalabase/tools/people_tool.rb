# frozen_string_literal: true

module Lalabase
  module Tools
    # What the two tools that read the people directory share (People S3): find_people lists
    # people, get_person reads one. Both read through People::Directory, the one owner of who
    # sees whom, and through nothing else: no Person.where, no Person.find.
    #
    # Rights come first: the people right (PersonPolicy.view_allowed?) is asked before anything
    # is read, and its absence is a refusal the model can say out loud instead of "nobody
    # found". It also asks for an ACTIVE membership, so a deactivated member who still holds the
    # right is refused too. The assistant's own gates (ai_enabled, assistant_enabled, the quota)
    # stay where they are; the directory has no switch of its own (decision E1).
    #
    # The directory belongs to the organisation, not to a project: like the help tools these
    # take no project, report no coverage and filter by no project. Their citations carry the
    # people area (Citations.person), which keeps an answer drawn on them with the asker.
    #
    # Which fields reach the AI provider is decided HERE and nowhere else (row, card): name,
    # salutation, function, department, company, email, phone, the additional details and the
    # date of the last contact. Never the notes (decision E2): free text about a third person,
    # it may hold anything, and the questions these tools are for are answered without it.
    class PeopleTool < Base
      REFUSAL = 'The asking user may not see the people directory of this organisation. Say so, ' \
                'and do not guess names or contact details.'

      # Reads context.actor for the rights and the directory, so the Runner's fail-closed bar
      # applies: a thread without an asker gets no person data.
      def self.requires_actor?
        true
      end

      # The refusal without the people right, or nil.
      def self.refusal(context)
        return nil if PersonPolicy.view_allowed?(context.actor, context.organisation)

        Result.refused(REFUSAL, reason: :people_directory)
      end

      def self.directory(context, query: nil, kind: 'all')
        People::Directory.new(viewer: context.actor, organisation: context.organisation, query: query, kind: kind)
      end

      # The id find_people hands out and get_person reads: "person:<uuid>" for a contact,
      # "member:<uuid>" for a member. The format of the link dialog
      # (Meetings::ParticipantLinkChoice), so a directory entry has one address, not two.
      def self.key_for(entry)
        Meetings::ParticipantLinkChoice.value_for(entry)
      end

      # One row of find_people: who it is and what they do, no contact details. A member's
      # name is the account's (Entry#plain_name), as on the people page.
      def self.row(entry)
        person = entry.person
        {
          id: key_for(entry),
          name: entry.plain_name,
          kind: entry.member? ? 'member' : 'contact',
          function: person&.function,
          department: person&.department,
          company: person&.company,
          last_contact: last_contact(entry.last_contact)
        }
      end

      # The card of get_person: the row plus how to reach the person. A member's email is the
      # account's, as on the people page; phone and details come from the row.
      def self.card(entry)
        person = entry.person
        row(entry).merge(
          salutation: person&.salutation,
          email: entry.member? ? entry.user.email : person&.email,
          phone: person&.phone,
          additional_details: details(person)
        )
      end

      # The additional details as label and value. A detail without a label is named by its
      # kind, as the people page names it by the kind's name.
      def self.details(person)
        list = person&.additional_details
        return [] unless list.is_a?(Array)

        list.map do |raw|
          detail = PersonDetail.new(raw)
          { label: detail.label.presence || detail.kind, value: detail.value }
        end
      end

      # The last contact as date and kind only (decision E3): no meeting title, no ticket
      # number, so an answer names nothing it does not cite. The date in the app's time zone.
      def self.last_contact(last)
        return nil if last.nil?

        { on: last.at.in_time_zone.to_date.iso8601, kind: last.kind.to_s }
      end
    end
  end
end
