# frozen_string_literal: true

class ObjektNavigationComponent < ApplicationComponent
  def initialize(object_class:, headers:, object_values:, object_list:, selected_object:, line_action:, list_action:)
    @object_class = object_class,
                    @headers = headers
    @object_values = object_values
    @object_list = object_list
    @selected_object = selected_object
    @line_action = line_action
    @list_action = list_action
  end

  def line_action_for(object)
    if @line_action.respond_to?(:call)
      @line_action.call(object)
    else
      @line_action
    end
  end
end
