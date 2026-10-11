# frozen_string_literal: true

module Neo
  # Renders Markdown as typeset prose — optionally clamped to a preview height
  # with a "weiterlesen" toggle that reveals the rest.
  #
  # ONE home for the three things every Markdown surface in the app used to spell
  # out by hand: the safe render (Lalabase::SafeMarkdown), the prose typography
  # (.md-preview, components/markdown_preview.css) and the preview clamp with its
  # Stimulus wiring (clamp_toggle_controller). Before this component the meeting
  # detail carried two copies of the clamp markup, saved analyses a third, and
  # the ticket summary was about to become a fourth — while views.css already
  # carried a note saying the third copy of the prose block had fired the
  # "unify at the third case" trigger.
  #
  # ⚠️ Takes Markdown SOURCE, never HTML: the render belongs to the component so
  # no call site can accidentally reach the page with an unsanitised string.
  # Callers that must prepare their source first (the meeting transcript needs
  # its frontmatter stripped and its speakers bolded) hand in the prepared
  # markdown — see MeetingsHelper#meeting_markdown_source.
  class MarkdownPreviewComponent < ViewComponent::Base
    # Font size of the prose block. :base inherits from the surrounding page.
    SIZE_CLASSES = { base: nil, md: 'md-preview--md', sm: 'md-preview--sm' }.freeze

    # Preview height. :short (~5 lines) is the default reading budget; :tall is
    # for a long raw document — today the meeting transcript — where a five-line
    # peek would say nothing about what is in there.
    CLAMP_CLASSES = { short: nil, tall: 'md-preview--clamp-tall' }.freeze

    # The class clamp_toggle adds/removes at runtime. Named here (not in the
    # template) because it is a CONTRACT with the stylesheet: the component hands
    # it to the controller through the Stimulus classes API, and the controller
    # is deliberately content-agnostic about which class that is.
    CLAMPED_CLASS = 'md-preview--clamped'

    # markdown:    Markdown source. Blank → the component renders nothing at all.
    # size:        :sm | :md | :base
    # clamp:       nil (full text, no toggle) | :short | :tall
    # more_label:  button text while clamped   (required when clamp is given)
    # less_label:  button text while expanded  (required when clamp is given)
    # class_name:  extra classes for the outermost element (spacing at the call site)
    def initialize(markdown:, size: :sm, clamp: nil, more_label: nil, less_label: nil, class_name: nil)
      super()
      @markdown = markdown
      @size = size
      @clamp = clamp
      @more_label = more_label
      @less_label = less_label
      @class_name = class_name

      validate!
    end

    # Nothing to typeset → no empty prose block, no dangling toggle.
    def render?
      @markdown.present?
    end

    def rendered_markdown
      Lalabase::SafeMarkdown.render(@markdown)
    end

    def clamp?
      @clamp.present?
    end

    # The element that carries the typography AND the clamp height. The clamp
    # MODIFIER (--clamp-tall) sits here rather than on the wrapper because it
    # only means anything together with CLAMPED_CLASS, which lands on this element.
    def body_classes
      ['md-preview', SIZE_CLASSES.fetch(@size), CLAMP_CLASSES.fetch(@clamp, nil),
       (@class_name unless clamp?)].compact_blank.join(' ')
    end

    def wrapper_classes
      @class_name
    end

    attr_reader :more_label, :less_label

    private

    # Loud on a typo. A misspelled size used to be a silently unstyled block, and
    # a clamp without labels an unreadable button — both of them the kind of
    # defect that only shows up on the one page nobody opened before the deploy.
    def validate!
      raise ArgumentError, "unknown size #{@size.inspect} (#{SIZE_CLASSES.keys.join(', ')})" \
        unless SIZE_CLASSES.key?(@size)
      raise ArgumentError, "unknown clamp #{@clamp.inspect} (nil, #{CLAMP_CLASSES.keys.join(', ')})" \
        unless @clamp.nil? || CLAMP_CLASSES.key?(@clamp)
      raise ArgumentError, 'clamp: needs more_label: and less_label:' \
        if clamp? && (@more_label.blank? || @less_label.blank?)
    end
  end
end
