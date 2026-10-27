# frozen_string_literal: true

module Meetings
  # Live claim matcher (Nachtrag: Teilnehmer-Claim) — a READ-ONLY query PORO, not an
  # actor: it never writes. For the acting user it finds external participant rows
  # (no user_id and no person_id, MeetingParticipant.external_in_projects) whose
  # normalized_name equals an active, real-named org member's, but ONLY within
  # meetings the acting user may WRITE (:meetings area), and minus
  # the (member, name) pairs that were explicitly rejected. Each returned group
  # offers the writer "link this external name to this member" — the write itself is
  # Actors::ClaimMeetingParticipants.
  #
  # Recomputed live on every index render (no stored suggestions), so it starts
  # matching automatically the moment a member fills in their real name — see the D1
  # decision in doc/gespraeche_plan.md.
  class ParticipantClaimMatches
    # One suggestion row: link `meeting_count` external participations named
    # `normalized_name` to the org member `user` (label `display_name`).
    Match = Data.define(:user, :normalized_name, :display_name, :meeting_count)

    def initialize(user:, organisation:)
      @user = user
      @organisation = organisation
    end

    def call
      return [] if writable_project_ids.empty?
      return [] if candidates_by_key.empty?

      counts = external_counts_by_key
      return [] if counts.empty?

      build_matches(counts)
    end

    private

    attr_reader :user, :organisation

    # Projects where the acting user may WRITE meetings — the reach of any claim.
    # A read-only or no-access user gets [] here and the whole thing short-circuits.
    def writable_project_ids
      @writable_project_ids ||= AccessCheck::ProjectAccessService.writable_meetings_project_ids(user, organisation)
    end

    # Active org members WITH a real name, grouped by normalized name. Members whose
    # full_name is blank are EXCLUDED on purpose: their display_name falls back to
    # the email prefix (User#display_name), which must never be matched on as if it
    # were a person's name. One normalized name may map to several members (true
    # doppelgängers) — each becomes its own suggestion.
    def candidates_by_key
      @candidates_by_key ||= active_named_members.each_with_object({}) do |member, grouped|
        key = MeetingParticipant.normalize_name(member.display_name)
        next if key.blank?

        (grouped[key] ||= []) << member
      end
    end

    # memberships + preloaded users in two queries (no N+1); the name filter runs in
    # Ruby because it depends on User#display_name's email fallback.
    def active_named_members
      organisation.memberships.where(active: true)
                  .includes(:user)
                  .filter_map(&:user)
                  .select { |member| member.active? && member.full_name.strip.present? }
    end

    # For the candidate keys, how many external rows match in writable meetings.
    # Single grouped query on the (organisation_id, normalized_name) index.
    def external_counts_by_key
      MeetingParticipant.external_in_projects(writable_project_ids)
                        .where(normalized_name: candidates_by_key.keys)
                        .group(:normalized_name)
                        .count
    end

    def build_matches(counts)
      rejected = rejected_pairs
      suggestions = counts.flat_map do |key, count|
        candidates_by_key.fetch(key, []).filter_map do |member|
          next if rejected.include?([member.id, key])

          Match.new(user: member, normalized_name: key,
                    display_name: member.display_name, meeting_count: count)
        end
      end
      suggestions.sort_by { |match| match.display_name.downcase }
    end

    # Explicitly rejected (member, name) pairs — tenant-scoped, so a sibling org's
    # rejection can never suppress a match here.
    def rejected_pairs
      MeetingParticipantClaimRejection.where(normalized_name: candidates_by_key.keys)
                                      .pluck(:user_id, :normalized_name).to_set
    end
  end
end
