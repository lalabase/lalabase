# frozen_string_literal: true

class PowerSearchPolicy < Struct.new(:user, :power_search)
  def index?
    # All authenticated users can use the search
    user.present?
  end

  def execute?
    # All authenticated users can run searches
    user.present?
  end
end
