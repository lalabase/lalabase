# frozen_string_literal: true

module Organisations
  # Read-only version history + unified diff for a wiki note (Lane B, Brick 4).
  # Renders into the Knowledge display frame, like notes#show/#edit.
  #
  # Access: the note is fetched through policy_scope(Note), so a user who cannot read the
  # note (project/area access) gets a 404 — never its history or its content.
  class NoteVersionsController < Organisations::BaseController
    before_action :set_note

    def index
      @versions = @note.note_versions.chronological.reverse_order # newest first
      render_in_frame('organisations/note_versions/history')
    end

    def show
      versions = @note.note_versions.chronological.to_a
      @version = versions.find { |version| version.id == params[:id] }
      raise ActiveRecord::RecordNotFound unless @version

      index = versions.index(@version)
      # Diff against the immediate predecessor (position-based, robust against equal
      # timestamps). The v0 baseline has none → VersionDiff renders everything as added.
      @previous = index.positive? ? versions[index - 1] : nil
      @diff = Wiki::VersionDiff.call(@previous, @version)
      render_in_frame('organisations/note_versions/diff')
    end

    private

    def set_note
      @project = current_organisation.projects.find(params[:project_id])
      # policy_scope is the real gate: a note the user cannot read is not in scope, so .find
      # raises RecordNotFound (404) without revealing it exists. authorize then satisfies
      # Pundit's verify_authorized for the readable case.
      @note = policy_scope(Note).where(project: @project).find(params[:note_id])
      authorize @note, :show?
    end

    def frame_id
      params[:frame_id].presence || 'knowledge_display_frame'
    end

    # turbo_frame_tag + render already return html-safe buffers, so no html_safe needed.
    def render_in_frame(partial)
      frame = helpers.turbo_frame_tag(frame_id) do
        helpers.render(partial: partial, locals: { note: @note, detail_frame_id: frame_id })
      end
      render html: frame, layout: false
    end
  end
end
