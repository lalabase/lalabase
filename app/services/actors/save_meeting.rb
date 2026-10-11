# frozen_string_literal: true

# app/services/actors/save_meeting.rb

module Actors
  # Tier 1 actor (BaseActor#call template): create or update a Meeting plus its
  # participants (Slice 1b) and the search/chat embedding wiring (Slice 6): the
  # embedding enqueue (gated on create_embeddings?) via #enqueue_jobs mirroring
  # SaveNote, plus a synchronous fragment purge on opt-out.
  #
  # Participants ride inside `params` under :participants (an array/hash of
  # {display_name, user_id}); the actor strips them out before touching Meeting
  # attributes and reconciles the meeting_participants rows in the same
  # transaction (add / remove / rename, no orphans). A nil payload means "not
  # provided" and leaves existing participants untouched.
  class SaveMeeting < BaseActor
    def initialize(project:, params:, current_user:, id: nil)
      super()
      # Extract BEFORE find_meeting: a new record does project.meetings.build(params),
      # which would choke on a :participants key that is not a Meeting column.
      @participants_payload = extract_participants(params)
      @meeting = find_meeting(project, params, id)
      @meeting_params = params
      @current_user = current_user
    end

    def record
      @meeting
    end

    def perform
      raise ActorError, 'Meeting not found' if @meeting.nil?

      if @meeting.id.present?
        @meeting.update!(@meeting_params)
      else
        @meeting.creator = @current_user
        @meeting.save!
      end

      sync_participants
      purge_fragments_if_deindexed
    end

    # Enqueue the embedding job after commit, gated on the search opt-in — mirrors
    # SaveNote (save_note.rb:27). The job self-guards on a blank plain_text_version,
    # so content is NOT re-checked here.
    #
    # Cost gate (review PR #247, #231 metering): re-embed only when the indexed text
    # or the opt-in itself changed — a title/participant edit must not re-embed a
    # whole transcript (every run costs credits). saved_change_to_create_embeddings?
    # covers re-enabling after a purge (status columns were reset to nil there); a
    # create counts every attribute as changed, so new meetings always pass. A run
    # that failed/quota-paused earlier is re-attempted via the org re-index, not here.
    def enqueue_jobs
      return unless @meeting&.create_embeddings?
      return unless @meeting.saved_change_to_plain_text_version? || @meeting.saved_change_to_create_embeddings?

      enqueue_after_commit do
        EmbeddingProcessingJob.perform_later(
          record_class: Meeting,
          record_id: @meeting.id,
          fragment_association: :fragments
        )
      end
    end

    private

    # Tenant-scoped lookup. A given id that matches no meeting in this tenant
    # (including a foreign-tenant id) yields nil, which #perform turns into a
    # "Meeting not found" failure. A blank id builds a new meeting in the project.
    def find_meeting(project, params, id)
      if id.present?
        Meeting.where(organisation: project.organisation, id: id).first
      else
        project.meetings.build(params)
      end
    end

    # Returns nil when the caller did not send a :participants key (leave rows as
    # is), otherwise an array of { display_name:, user_id: } — blank names dropped.
    def extract_participants(params)
      return nil unless params.respond_to?(:key?) && params.key?(:participants)

      raw = params.delete(:participants)
      entries = raw.is_a?(Array) ? raw : raw.values
      entries.filter_map do |entry|
        h = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry
        display = (h[:display_name] || h['display_name']).to_s
        next if display.strip.empty?

        { display_name: display, user_id: (h[:user_id] || h['user_id']).presence }
      end
    end

    def sync_participants
      return if @participants_payload.nil?

      desired = build_desired_participants(@participants_payload)
      guard_against_duplicates!(desired)
      reconcile_participants(desired)
    end

    # Resolves each payload row to a canonical desired participant. A user_id that
    # is not an org member is dropped to nil (kept as an external name) — this
    # blocks linking a meeting to a foreign-org user via a tampered POST.
    def build_desired_participants(payload)
      payload.map do |row|
        # allowed_user_ids is only queried when a link is actually claimed.
        user_id = row[:user_id].presence
        user_id = nil if user_id && !allowed_user_ids.include?(user_id)
        {
          display_name: row[:display_name].strip.gsub(/\s+/, ' '),
          normalized_name: MeetingParticipant.normalize_name(row[:display_name]),
          user_id: user_id
        }
      end
    end

    def allowed_user_ids
      @allowed_user_ids ||= @meeting.organisation.users.pluck(:id).to_set
    end

    # The DB indexes already guard these; we surface them as readable Meeting-level
    # form errors instead of a raw RecordNotUnique deep in a participant save.
    def guard_against_duplicates!(desired)
      names = desired.map { |d| d[:normalized_name] }
      @meeting.errors.add(:base, :duplicate_participant_name) if names.uniq.size != names.size

      user_ids = desired.filter_map { |d| d[:user_id] }
      @meeting.errors.add(:base, :duplicate_participant_user) if user_ids.uniq.size != user_ids.size

      raise ActorError, @meeting.errors.full_messages if @meeting.errors.any?
    end

    def reconcile_participants(desired)
      keep = desired.map { |d| d[:normalized_name] }
      # Remove participants no longer present (empty desired -> clears them all).
      @meeting.meeting_participants.where.not(normalized_name: keep).destroy_all

      # Load the survivors once (no per-row SELECT / N+1) and upsert against them.
      existing = @meeting.meeting_participants.index_by(&:normalized_name)
      # Share the already-loaded org instance so the belongs_to :organisation
      # presence validation does not re-query it once per participant (N+1).
      org = @meeting.organisation
      desired.each do |d|
        participant = existing[d[:normalized_name]] || @meeting.meeting_participants.build
        participant.organisation = org
        participant.display_name = d[:display_name]
        participant.user_id = d[:user_id]
        participant.save!
      end
    end

    # PII fail-safe (Gespräche Slice 6, plan §5/§7): a meeting that is NOT indexed
    # — opt-in off, or no content to index — must leave NO retrievable fragments.
    # Runs synchronously inside the actor transaction (unlike Note, which keeps
    # stale fragments on opt-out). Also resets the status columns to nil ("never
    # attempted") so a later re-index re-processes the meeting if the opt-in
    # returns — a lingering flag: true would make PendingEmbeddings skip it.
    def purge_fragments_if_deindexed
      return if @meeting.create_embeddings? && @meeting.plain_text_version.present?

      # Sidecar purge (embedding v2 PR 2): remove the fragments' content_embeddings
      # rows BEFORE the callback-free delete_all removes the fragments (the subselect
      # needs them), inside this same actor transaction. A de-indexed transcript must
      # leave no retrievable trace and the orphan GC only ships in PR 3.
      ContentEmbedding.purge_for(embeddable_type: 'Fragment', embeddable_ids: @meeting.fragments.select(:id))
      @meeting.fragments.delete_all
      # deliberate: reset the two status
      # columns only, bypassing callbacks (no broadcast / no plain_text_version recompute).
      @meeting.update_columns(embeddings_creation_flag: nil, embedding_creation_error: nil)
    end
  end
end
