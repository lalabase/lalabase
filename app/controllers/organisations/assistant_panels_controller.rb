# frozen_string_literal: true

# S3a T4: the body of the companion panel (assistant plan §7.7).
#
# The panel SHELL lives in the application layout as a data-turbo-permanent node
# so it survives every Turbo Drive visit as a living DOM element. Its CONTENT is
# this endpoint, loaded lazily into a turbo frame the first time somebody opens
# the panel (pattern: layouts/_personal_tasks_drawer). Two reasons it is not
# inlined into the layout:
#
#   * cost -- the shell renders on every request, and inlining would render a
#     whole transcript per page load only for Turbo to discard it again,
#   * duplicate DOM ids -- rendered WITHOUT the application layout, this response
#     can never carry a second copy of the shell. (The other half of that problem,
#     the chat frame's id colliding with the one on a chat PAGE, is solved where
#     it arises: the panel passes its own frame_id to ChatContainerComponent. The
#     chatposts container is chat-derived and unique by construction.)
#
# This is the ONLY place the org-wide transcript is rendered from since T4;
# assistant_chats#show hands its thread over here instead of being a page of its
# own (L11: the assistant is a companion lane, not a navigation target).
module Organisations
  class AssistantPanelsController < Organisations::BaseController
    layout false

    # GET /org/:organisation_id/assistant_panel
    #
    # Params (all optional, all client-controlled -- hence the finders below):
    #   new     -- '1' forces the empty composer even though threads exist
    #   chat_id -- open THIS thread (the redirect target of an assistant_chats
    #              link); anything the user does not own falls through to the
    #              default thread.
    #   list    -- '1' serves the list of earlier conversations INSTEAD of a
    #              transcript (S3c T1, plan §7.6)
    #   settings -- '1' serves the assistant's settings INSTEAD of a transcript
    #              (the gear in the panel header)
    #   current -- with list=1: which thread the panel is showing, so the list
    #              can mark it and offer the way back.
    def show
      return render_settings if params[:settings] == '1'
      return render_history if params[:list] == '1'

      @chat = requested_chat

      # No record yet means "you may start one": that is create?, and asking it
      # is what keeps the §13-2 pair in front of the empty composer too. With a
      # record it is the ordinary read gate. Either way verify_authorized is
      # satisfied by a question that matches what the response actually offers.
      if @chat
        authorize @chat, :show?
      else
        authorize Chat.new(user: current_user, organisation: @current_organisation), :create?
      end
    end

    # GET /org/:organisation_id/assistant
    #
    # The shareable address (S3c T2, §7.5/L3). It hands the FULL VIEW over the way
    # assistant_chats#show hands a thread over: through the address, because a
    # data-turbo-permanent node never sees the markup the server rendered for it.
    # Then it sends the user to a real page, so a bookmarked link lands somewhere
    # that works rather than on a bare frame response.
    #
    # ⚠️ Known limit, deliberately not papered over: below the panel's breakpoint
    # (lg, 1024px) there is no companion lane at all -- the whole node is
    # `hidden lg:block` -- so this address arrives on a phone and shows the org
    # start page with nothing opened. The mobile assistant is its own render path
    # (§7.5) and belongs to S4; pretending otherwise here would mean a link that
    # silently does nothing on the device most likely to receive it.
    def full
      authorize Chat.new(user: current_user, organisation: @current_organisation), :create?

      redirect_to organisation_root_path(organisation_id: @current_organisation.id,
                                         assistant: AssistantPanelState::MODE_FULL)
    end

    private

    # The assistant's settings (the gear), a third STATE OF THIS FRAME beside the
    # transcript and the history list, for the reason the list gives: the panel is
    # one lane, and a second frame or a page of its own would be a second place to
    # keep in sync with a node the server can never re-render.
    #
    # Same door as the list and the empty composer (§13-2: operator flag plus
    # use_assistant), because the question is the same one: may you use the
    # assistant at all. The settings themselves are per user and per org, so there
    # is no per-record read to gate beyond that.
    def render_settings
      authorize Chat.new(user: current_user, organisation: @current_organisation), :create?

      # The way back. Resolved against the person's OWN threads rather than trusted
      # from the parameter: `current` is as client-settable as `chat_id`, and this
      # value ends up in a link the settings view renders. A foreign or made-up id
      # simply yields no thread, and the way back falls to the panel default.
      @current_chat = requested_own_thread

      render :settings
    end

    def requested_own_thread
      requested = params[:current].presence
      return nil if requested.nil?

      own_threads.find_by(id: requested)
    end

    # The list of earlier conversations (plan §7.6), a STATE OF THIS FRAME rather
    # than a page or a second frame: before it existed the panel served
    # own_threads.first and nothing linked to any other thread, so everything
    # older than the newest was reachable only for somebody who had kept a
    # ?assistant_chat_id= address.
    #
    # Deliberately UNPAGINATED: a person accumulates their own threads one
    # conversation at a time, and a cap that silently hides the oldest ones would
    # recreate the very problem this list solves. If the lists ever get long
    # enough to matter, that is a visible change with a visible answer (search or
    # paging), not something to pre-empt with a quiet LIMIT.
    def render_history
      # The SAME door the empty composer below goes through, and for the same
      # reason: the question this surface answers is "may you use the assistant
      # at all", which is what create? asks (operator flag plus use_assistant).
      authorize Chat.new(user: current_user, organisation: @current_organisation), :create?

      @threads = own_threads.to_a
      @current_chat = requested_current_thread

      # Two surfaces for one list: the overlay that replaces the transcript in
      # companion mode (T1), and the standing lane beside it in the full view
      # (T2). They differ in the frame they answer into and in whether a way back
      # makes sense, so they are two views over ONE component rather than one
      # view with a branch in it.
      #
      # The frame id is decided HERE and never by the client: a frame name taken
      # from a parameter would be user input in the very attribute Turbo aims at.
      return render :history_lane if params[:lane] == '1'

      render :history
    end

    # `current` is as client-settable as `chat_id`, and unlike it the value ends
    # up in the rendered markup. So it is resolved against the threads ALREADY
    # loaded rather than queried: a foreign or made-up id marks nothing, and the
    # list never asks the database about a record this viewer may not see.
    #
    # ⚠️ Which surface actually PRINTS it decides where the test bites. Today only
    # the overlay does, through the back arrow's href; the lane has no such exit,
    # and a twin test there was green even with this method mutated to a bare
    # Chat.find_by. Give the lane an exit that renders @current_chat -- a back
    # link, a heading naming the open thread -- and it needs its own test, because
    # the one guarding this method lives in the OTHER surface.
    def requested_current_thread
      requested = params[:current].presence
      return nil if requested.nil?

      @threads.detect { |chat| chat.id == requested }
    end

    # Owner-scoped, exactly like AssistantChatsController#set_chat: `find_by`
    # rather than `find` because a stale chat_id in a bookmarked address must not
    # answer with a 404 page rendered INSIDE the panel. Falling through to the
    # newest own thread is fail-closed -- nothing foreign is ever rendered, the
    # id is simply not honoured.
    def requested_chat
      return nil if params[:new] == '1'

      requested = params[:chat_id].presence
      # The presence check is not cosmetic: without it every panel load without a
      # chat_id asks the database for `WHERE id IS NULL`, which can never match.
      (requested && own_threads.find_by(id: requested)) || own_threads.first
    end

    # Newest first. chats.last_message_at is not maintained anywhere (dead
    # column), so creation order is the honest ordering: a thread is created when
    # the user starts a new conversation, which is the moment they mean.
    def own_threads
      Chat.org_threads.where(user_id: current_user.id).order(created_at: :desc)
    end
  end
end
