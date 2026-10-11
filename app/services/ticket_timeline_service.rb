# frozen_string_literal: true

# Service for building the chronological timeline of a ticket
# Combines posts, time sessions, and activities with optimal performance
class TicketTimelineService
  # The ticket's birth as a regular timeline row ("Ticket angelegt · G. Boyke",
  # user mockup 05.09.2026). A synthetic marker built from the ticket record
  # itself, not the 'created' Activity: old tickets predate the tracking, and
  # created_at/creator are always there. The 'created' Activity is filtered
  # out below like post_added - the marker replaces it.
  CreationMarker = Struct.new(:ticket) do
    delegate :created_at, :creator, to: :ticket
  end

  # Collapse click cascades (designer round 05.09.2026): ADJACENT activities
  # on the same field by the same person, each no more than 30 minutes after
  # the previous one, become one ActivityRun - the timeline row shows the net
  # result, the single steps sit in a disclosure. Any other item between two
  # steps breaks the run: the reader saw something happen in between.
  AGGREGATE_WINDOW = Activities::RunCollapser::WINDOW
  AGGREGATE_FIELD_FOR_ACTION = Activities::RunCollapser::FIELD_FOR_ACTION

  # A run sorts and dates by its NEWEST step (the moment the cascade ended);
  # oldest/newest stay order-independent because build_timeline reverses the
  # activities array for a newest-first timeline so the disclosure reads in
  # the same direction as the list around it.
  ActivityRun = Activities::RunCollapser::ActivityRun

  def initialize(ticket, user = nil)
    @ticket = ticket
    @user = user
    @timeline_items = nil
  end

  # Main method - returns the chronologically sorted timeline
  def timeline_items
    @timeline_items ||= build_timeline
  end

  # Clears the cache - useful in tests or when the timeline needs to be reloaded
  def clear_cache
    @timeline_items = nil
    self
  end

  # Returns the number of timeline items without loading the items
  def timeline_count
    posts_count + time_sessions_count + activities_count
  end

  # Returns whether the timeline is empty without loading the items
  def empty?
    timeline_count == 0
  end

  # The one owner of "which moment sorts and dates this item". Public class
  # method since T4: the view's day grouping asks the same rule the sort
  # uses, so a chunk boundary can never disagree with the order.
  def self.timestamp_for(item)
    case item
    when Post
      item.created_at
    when TimeSession
      # TimeSession uses occurred_on for sorting
      item.occurred_on.present? ? item.occurred_on.to_time : item.created_at
    when Activity
      item.created_at
    else
      # Fallback for unknown item types
      item.respond_to?(:created_at) ? item.created_at : Time.current
    end
  end

  # Does this item's timestamp name a MOMENT, or only a day?
  #
  # A time session is booked on a day (occurred_on), not at a clock time, and
  # timestamp_for turns that date into 00:00 so it can sort. Printing that as
  # a time would invent a precision the record does not have: every entry
  # would claim it happened at midnight. The timeline row therefore shows no
  # time for these - the day header above it already says everything the
  # record knows.
  def self.date_only?(item)
    item.is_a?(TimeSession) && item.occurred_on.present?
  end

  private

  def build_timeline
    posts = load_posts
    time_sessions = load_time_sessions
    activities = load_activities

    # Combine and sort - direction depends on the user preference. The
    # creation marker rides along and sorts by the ticket's created_at like
    # any other item.
    combined_items = (posts + time_sessions + activities + [CreationMarker.new(@ticket)]).sort_by do |item|
      timestamp_for_item(item)
    end

    combined_items = Activities::RunCollapser.for_ticket(combined_items)

    # Reverse order if user preference is set to reverse. The steps inside a
    # run flip with the list, so the disclosure reads in the same direction
    # as the timeline around it (designer round 05.09.2026).
    if reverse_order?
      combined_items.reverse!
      combined_items.each { |item| item.activities.reverse! if item.is_a?(ActivityRun) }
    end

    combined_items
  end

  # Always a query through Post.readable_by, never a preloaded association: a
  # preload carries every post of the ticket, private ones included.
  def load_posts
    readable_posts
      .includes(
        { user: { avatar_attachment: :blob } },
        :rich_text_content,
        post_reactions: :user,
        post_documents: { post_document_file_attachment: :blob }
      )
      .order(:created_at)
      .to_a
  end

  def readable_posts
    @ticket.posts.readable_by(@user, @ticket.organisation)
  end

  def load_time_sessions
    # If a user was passed, apply the permission check
    if @user
      # Account admins can see all time sessions
      return @ticket.time_sessions.includes(:creator).order(:occurred_on).to_a if @user.account_admin_in?(@ticket.organisation)

      # Fetch the TimeSessionPermission for the project
      permission = @user.time_session_permissions.backed_by_project_access.find_by(project_id: @ticket.project_id)

      # No permission = no time sessions visible
      return [] if permission.nil?

      # Load time sessions depending on the permission level
      if permission.can_view_all?
        # User can see all time sessions in the project
        @ticket.time_sessions.includes(:creator).order(:occurred_on).to_a
      elsif permission.can_view_own?
        # User can only see their own time sessions
        @ticket.time_sessions.where(creator_id: @user.id).includes(:creator).order(:occurred_on).to_a
      else
        # User has no visibility permission
        []
      end
    elsif @ticket.association(:time_sessions).loaded?
      # Fallback: if no user was passed (e.g. admin view), load all
      @ticket.time_sessions.to_a
    else
      @ticket.time_sessions
             .includes(:creator)
             .order(:occurred_on)
             .to_a
    end
  end

  def load_activities
    # Use the already-loaded association if available
    activities = if @ticket.association(:activities).loaded?
                   @ticket.activities.to_a
                 else
                   # Optimized query with required associations
                   @ticket.activities
                          .includes(:actor, :secondary)
                          .order(:created_at)
                          .to_a
                 end

    # Filter out redundant activities: the post itself is already in the
    # timeline (post_added), and the ticket's birth renders as the always
    # visible CreationMarker row (created). Everything else stays for the
    # audit trail.
    activities.reject { |activity| %w[post_added created].include?(activity.action) }
  end

  def timestamp_for_item(item)
    self.class.timestamp_for(item)
  end

  def posts_count
    readable_posts.count
  end

  def time_sessions_count
    @ticket.association(:time_sessions).loaded? ? @ticket.time_sessions.size : @ticket.time_sessions.count
  end

  def activities_count
    @ticket.association(:activities).loaded? ? @ticket.activities.size : @ticket.activities.count
  end

  # Check if timeline should be displayed in reverse order (newest first)
  def reverse_order?
    @user&.preference_store&.prefers_reverse_timeline? || false
  end
end
