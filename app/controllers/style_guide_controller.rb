# frozen_string_literal: true

class StyleGuideController < ApplicationController
  # Skip authentication in development
  skip_before_action :authenticate_user!, if: -> { Rails.env.development? }
  skip_before_action :load_tenant_from_session
  skip_before_action :load_user_preferences

  layout 'style_guide'

  # Code samples for the name-display page.
  #
  # They live in the controller, not in the view, because
  # spec/views/name_display_register_guard_spec.rb turns the CI red on a raw
  # `.full_name` anywhere under app/views - and showing that anti-pattern is
  # half the point of the page. The guard does not scan app/controllers, so the
  # samples sit here rather than in its allowlist: an exception granted to a
  # demo page would weaken a guard that has already caught two real drifts.
  NAME_DISPLAY_SAMPLES = {
    pair: '<%= viewer_user_chip(user) %>',
    list: '<%= viewer_user_list(ticket.assignees) %>',
    prose: '<%= t(".assigned_by", name: viewer_display_name(ticket.creator)) %>',
    picture_only: '<%= render Neo::Users::AvatarComponent.new(user: user, size: :xs) %>',
    pinned_mode: '<%= render Neo::Users::NameComponent.new(user: user, mode: "initial_last") %>',
    preload: 'Ticket.includes(assignees: { avatar_attachment: :blob })',
    raw_name: '<%= user.full_name %>',
    raw_display_name: '<%= user.display_name %>',
    external_avatar: "<%= image_tag \"https://ui-avatars.com/api/?name=\#{user.full_name}\" %>"
  }.freeze

  def index
    # Main style guide page
  end

  def buttons
    # Button components showcase
  end

  def forms
    # Form components showcase (future)
  end

  def colors
    # Color palette
  end

  def themes
    # Theme modes (light/dark/pop) + token layer
  end

  def typography
    # Typography examples
  end

  def headers
    # Header and navigation components
  end

  def modals
    # Modal components showcase
  end

  def drag_drop
    # Drag and drop components showcase
  end

  def cards
    # Card components showcase
  end

  def flash_messages
    # Flash messages components showcase
  end

  def tags
    # Tag components showcase
  end

  def activities
    # Activity feed components showcase
    # Create sample activities for demonstration
    @sample_activities = create_sample_activities
  end

  def empty_states
    # Empty-state pattern: reduced first-use rendering vs. filtered no-results
  end

  def name_display
    # Avatar chip + name spelling (docs/dokumentation/namensanzeige_flaechenregister.md).
    #
    # Unsaved User records on purpose: they carry the real User::NameDisplay
    # methods, so the page renders THE components rather than a lookalike, and
    # it needs no tenant, no database row and no fixtures. An unsaved user
    # never has an avatar attached, so every chip here draws initials; the
    # picture path is documented in prose on the page instead.
    @demo_user = User.new(first_name: 'Max', last_name: 'Mustermann', email: 'max@example.com')
    @demo_long_name = User.new(first_name: 'Alexandra', last_name: 'Schmidt-Reinhardt',
                               email: 'a.schmidt@example.com')
    @demo_single_name = User.new(first_name: 'Cher', email: 'cher@example.com')
    @demo_nameless = User.new(email: 'k.pietsch@example.com')
    @samples = NAME_DISPLAY_SAMPLES
  end

  def z_index
    # Z-index scale and layer hierarchy
  end

  def changelog
    # Changelog page
  end

  private

  def create_sample_activities
    # Mock activity objects for demonstration
    Struct.new(:id, :action, :actor, :created_at, :attribute_changes, :parameters) do
      def actor
        Struct.new(:full_name).new('Max Mustermann')
      end
    end.tap do |activity_class|
      return [
        activity_class.new(1, 'created', nil, 2.hours.ago, nil, { 'display_name' => 'Beispiel Gruppe' }),
        activity_class.new(2, 'updated', nil, 1.hour.ago, {
                             'name' => ['Alte Gruppe', 'Neue Gruppe'],
                             'description' => ['Alte Beschreibung', 'Neue ausführliche Beschreibung mit mehr Details']
                           }, {}),
        activity_class.new(3, 'marked_as_billed', nil, 30.minutes.ago, nil, {
                             'invoice_number' => 'RE-2024-001',
                             'billed_at' => Time.current
                           }),
        activity_class.new(4, 'billed_data_changed', nil, 15.minutes.ago, {
                             'invoice_number' => %w[RE-2024-001 RE-2024-001-V2],
                             'name' => ['Alte Bezeichnung', 'Korrigierte Bezeichnung']
                           }, { 'warning_acknowledged' => true }),
        activity_class.new(5, 'time_sessions_added', nil, 5.minutes.ago, nil, {
                             'count' => 12,
                             'total_duration' => '24:30 Stunden'
                           })
      ]
    end
  end
end
