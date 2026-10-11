# frozen_string_literal: true

# A picker with a text field. Two modes:
# - Without url: the options come in as `options:` and the typed text filters them in the
#   browser (meeting and time pickers).
# - With url: the typed text asks the server (neo_autosuggest_controller.js with
#   lib/autosuggest_search.js). The endpoint answers { options: [{ value, text, detail }] }
#   for ?q=; `options:` is not listed then, and `selected_text:` names the confirmed choice
#   (after a refused save the form comes back with it). The ticket picker of the "Link" modal.
class NeoAutosuggestComponent < ViewComponent::Base
  def initialize(
    name:,
    options:,
    selected: nil,
    placeholder: I18n.t('components.neo_autosuggest.placeholder'),
    include_blank: true,
    blank_text: I18n.t('components.neo_autosuggest.blank_text'),
    form: nil,
    url: nil,
    selected_text: nil,
    **html_options
  )
    @name = name
    @options = options
    @selected = selected
    @placeholder = placeholder
    @include_blank = include_blank
    @blank_text = blank_text
    @form = form
    @url = url
    @selected_text = selected_text
    @html_options = html_options
  end

  private

  def server?
    @url.present?
  end

  # Server mode: a <label for=...> names the field, so its id can come from the caller.
  def input_id
    @html_options[:input_id] || "#{component_id}_input"
  end

  def component_id
    @component_id ||= "neo_autosuggest_#{SecureRandom.hex(4)}"
  end

  def input_name
    if @form.respond_to?(:object_name) && @form.object_name.present?
      "#{@form.object_name}[#{@name}]"
    else
      @name
    end
  end

  def selected_text
    return @selected_text.to_s if server?
    return @blank_text if @selected.blank? && @include_blank

    option = @options.find { |opt| opt[:value].to_s == @selected.to_s }
    if option
      option[:text]
    elsif @include_blank
      @blank_text # Fallback to blank text if selected option is not found
    else
      @placeholder
    end
  end

  def component_classes
    [
      'relative w-full',
      @html_options[:class]
    ].compact.join(' ')
  end

  def input_classes
    'block w-full border-stroke rounded text-xs px-3 py-2 focus:outline-none focus:-translate-x-0.5 focus:-translate-y-0.5 focus:shadow-sm focus:ring-0 bg-surface-raised cursor-pointer'
  end

  def dropdown_classes
    'absolute top-full left-0 right-0 z-dropdown bg-surface-raised border border-slate-200 rounded mt-1 max-h-48 overflow-auto shadow-sm transform translate-y-1'
  end

  OPTION_CLASSES = 'px-3 py-2 text-xs cursor-pointer hover:bg-lime-100 border-b border-gray-200 last:border-b-0'

  def option_classes(option)
    base_classes = OPTION_CLASSES
    base_classes += ' bg-lime-200 font-medium' if option[:value].to_s == @selected.to_s
    base_classes
  end
end
