# frozen_string_literal: true

module Neo
  module Chat
    # The context offer (S4 T2 step 5b, plan §7.3): the page you just navigated
    # to names its object, and the panel offers to point at it. It never takes
    # over by itself -- that is the whole rule of this bullet, and the reason
    # this is a strip with a button rather than a silent write.
    #
    # Empty and hidden on first paint: the offer is CLIENT knowledge (which page
    # is showing, which object it names), so the server has nothing true to say
    # about it. assistant_panel_controller fills it in and reveals it; every
    # target and action here belongs to that controller.
    #
    # ⚠️ It used to live in the panel SHELL, below everything, because anything
    # the client writes into the assistant_panel_body frame is gone at the next
    # frame load (thread switch, "Neuer Chat", the refresh after an answer).
    # Moved into the frame on 27.08.2026 for a reason that outweighs that: at the
    # bottom edge of the panel, under the field, under the style row and under
    # the transparency line, nobody looked at it. It now sits directly above the
    # row that shows the reference it is offering to set, where the eye already
    # is. The frame-load problem is answered where it arises --
    # handleChatFrameLoad re-runs the offer after every load of this frame.
    #
    # Panel only (ChatContainerComponent#panel? and the empty-state partial): the offer is about the page you
    # navigated to WHILE the companion panel travels with you. A chat page has no
    # such second surface, and rendering it there would put a second copy of the
    # fixed ids below into a document that can show both at once.
    class ContextOfferComponent < ViewComponent::Base
    end
  end
end
