# frozen_string_literal: true

# Mobile list/detail switch for list pages (tickets, knowledge):
# below the breakpoint the page shows EITHER the list OR the detail
# (with a back button), controlled via selected_item.
class NeoMobileTicketViewComponent < ViewComponent::Base
  renders_one :list
  renders_one :detail

  def initialize(
    back_url:,
    back_label:,
    selected_item: nil,
    show_detail: false
  )
    @back_url = back_url
    @back_label = back_label
    @selected_item = selected_item
    @show_detail = show_detail || selected_item.present?
  end

  private

  attr_reader :selected_item, :show_detail, :back_url, :back_label

  def container_classes
    'mobile-ticket-view min-h-screen'
  end

  def show_list?
    !show_detail
  end

  def show_detail_view?
    show_detail && selected_item.present?
  end
end
