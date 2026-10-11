# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Taggable, type: :concern do
  it_behaves_like 'a taggable model', :note
  it_behaves_like 'a taggable model', :document
  it_behaves_like 'a taggable model', :ticket
end
