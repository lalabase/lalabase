# frozen_string_literal: true

# The badge on a single booking: which billing it sits in, and whether that one
# is invoiced yet.
#
# Its words used to be hardcoded German strings ('Abgerechnet', 'In Gruppe', and
# two tooltips built by interpolation) - a fifth name for states that already had
# four, and an i18n violation that made the English page render German. Since S1
# the state words come from TimeSessionsHelper#time_billing_state_label and the
# tooltips from components.time_session_billing_status.*.
class TimeSessionBillingStatusComponent < ViewComponent::Base
  def initialize(time_session:, show_link: true, size: :small)
    @time_session = time_session
    @show_link = show_link
    @size = size
  end

  private

  def badge_classes
    base_classes = 'inline-flex items-center rounded-full font-medium border'

    size_classes = case @size
                   when :small
                     'px-2 py-0.5 text-xs'
                   when :medium
                     'px-3 py-1 text-sm'
                   else
                     'px-2 py-0.5 text-xs'
                   end

    color_classes = if @time_session.billed?
                      'bg-green-100 text-green-800 border-green-800'
                    elsif @time_session.grouped?
                      'bg-yellow-100 text-yellow-800 border-yellow-800'
                    else
                      ''
                    end

    "#{base_classes} #{size_classes} #{color_classes}"
  end

  def status_text
    if @time_session.billed?
      helpers.time_billing_state_label('billed')
    elsif @time_session.grouped?
      group_name
    end
  end

  # A billing always has a name (TimeSessionGroup validates its presence), so the
  # fallback is only for a row whose billing went missing under it. It says the
  # state rather than inventing a word for "there was one".
  def group_name
    @time_session.time_session_group&.name || helpers.time_billing_state_label('in_billing')
  end

  def tooltip_text
    return nil unless @time_session.grouped?

    if @time_session.billed?
      # "Rechnung" on purpose: this one really is the invoice number and its date,
      # which is the distinction D1 draws between Rechnung and Abrechnung.
      t('components.time_session_billing_status.tooltip_billed',
        invoice: @time_session.time_session_group.invoice_number,
        date: I18n.l(@time_session.time_session_group.billed_at, format: :long))
    else
      t('components.time_session_billing_status.tooltip_in_billing', name: group_name)
    end
  end

  def render?
    @time_session.grouped?
  end
end
