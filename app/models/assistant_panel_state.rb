# frozen_string_literal: true

# S3a T4 (assistant plan §7.7): the companion panel's open/closed state and its
# width, as they arrive from the browser.
#
# WHY A COOKIE and not a user preference: the width comes out of a pointer drag,
# so a preference would mean dozens of writes per second against the database for
# a value that is a property of THIS screen, not of the person. The cookie costs
# no request at all, and it lets the SERVER render <main> already shifted on a
# hard reload instead of letting the page jump once JavaScript wakes up.
#
# This class is the ONE owner of the format and the bounds. The Stimulus
# controller receives MIN/MAX as values from the shell partial rather than
# carrying its own copies, so a change here cannot leave a second pair of numbers
# behind (the spike had exactly that duplication).
class AssistantPanelState
  COOKIE_NAME = 'assistant_panel'

  # Narrower than MIN and the chat stops being a chat; wider than MAX and the
  # page it accompanies is no longer the main thing on screen.
  MIN_WIDTH = 280
  MAX_WIDTH = 640
  DEFAULT_WIDTH = 380

  # The sidebar's own width. Twin of `w-64` on #sidebar and `lg:ms-64` on <main>
  # in layouts/application.html.erb: the panel docks to the right of the sidebar,
  # so the content offset is both widths together. Change one, change the other.
  SIDEBAR_WIDTH = 256

  # The third state of the same chat (S3c T2, plan §4/L11): companion panel or
  # full view. It lives in this cookie rather than in a preference for the same
  # reason the width does -- it belongs to this screen, and the server has to
  # know it before the first paint or the page jumps once JavaScript wakes up.
  MODE_PANEL = 'panel'
  MODE_FULL = 'full'
  MODES = [MODE_PANEL, MODE_FULL].freeze

  # "<0|1>:<width>[:<mode>]", e.g. "1:420" or "1:420:full". Deliberately not
  # JSON: it has to be written by a line of JavaScript and read by a regular
  # expression, and anything a stray value could do here should end in the
  # default rather than in a parser.
  #
  # The mode group is OPTIONAL, and that is not politeness towards old code: every
  # browser that has opened the panel before this ticket carries a two-part
  # cookie. A required third group would fail to match all of them at once, and
  # the panel would snap shut for everybody on the deploy.
  COOKIE_FORMAT = /\A([01]):(\d{2,4})(?::(\w+))?\z/

  attr_reader :width, :mode

  # Anything unparseable yields the closed default. Fail-closed is the friendly
  # direction here too: a panel that stays shut is a non-event, a panel that
  # opens itself over the page is not.
  def self.from_cookie(raw)
    match = COOKIE_FORMAT.match(raw.to_s)
    return new if match.nil?

    new(open: match[1] == '1', width: match[2].to_i, mode: match[3])
  end

  def initialize(open: false, width: DEFAULT_WIDTH, mode: MODE_PANEL)
    @open = open
    @width = width.clamp(MIN_WIDTH, MAX_WIDTH)
    # Unknown modes become the companion panel, the same fail-closed direction
    # the whole parser takes: a panel that stays modest is a non-event, one that
    # covers the page uninvited is not.
    @mode = MODES.include?(mode) ? mode : MODE_PANEL
  end

  def open?
    @open
  end

  # Full only while open. The two are one piece of furniture, and "closed but
  # maximised" is a state with nothing to show -- it would surface as a full
  # screen appearing out of nowhere the next time somebody hits Cmd+J.
  def full?
    open? && mode == MODE_FULL
  end

  # How far <main> has to move to the right while the panel is open.
  #
  # nil in the full view: there the panel covers the page rather than standing
  # next to it, so there is nothing to push aside. Shifting anyway would move a
  # page nobody can see and leave the gap behind on the way back down.
  def content_offset
    return nil if full?

    SIDEBAR_WIDTH + width
  end
end
