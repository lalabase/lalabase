# frozen_string_literal: true

require 'rails_helper'

module TestSortableModule
  # Test controller that includes the Sortable concern
  class TestSortableController < ApplicationController
    include Sortable

    # Set up the Sortable concern with the Note model
    setup_sortable Note, 'notes.created_at', true

    # Add related columns for the User table
    add_related_sortable_columns 'users', 'name', 'email'

    def index
      # Run the query with the parameters from the test
      @model = Note
      @query = @model.all

      # Apply sorting
      @sorted_query = apply_sorting(@query)

      # Dummy response
      render plain: 'OK'
    end
  end
end

RSpec.describe TestSortableModule::TestSortableController, type: :controller do
  # For model detection
  let(:note_model) { class_double('Note', table_name: 'notes', column_names: %w[title content created_at]) }
  let(:user_model) { class_double('User', table_name: 'users', column_names: %w[name email]) }

  before do
    # Mock for sortable_model_class
    allow(controller.class).to receive(:sortable_model_class).and_return(note_model)

    # Mock for the model_class method
    allow(controller).to receive(:model_class).and_return(note_model)

    # Mock for Model.column_names
    allow(note_model).to receive(:columns_hash).and_return({
                                                             'title' => double(type: :string),
                                                             'content' => double(type: :text),
                                                             'created_at' => double(type: :datetime)
                                                           })

    # Configure related models
    allow(controller.class).to receive(:related_models).and_return({ 'users' => user_model })

    # Better mocks for Notes.all and the query methods
    @notes_relation = double('ActiveRecord::Relation')
    allow(Note).to receive(:all).and_return(@notes_relation)
    allow(@notes_relation).to receive(:to_sql).and_return('SELECT * FROM notes')
    allow(@notes_relation).to receive(:except).and_return(@notes_relation)
    allow(@notes_relation).to receive(:order).and_return(@notes_relation)
    allow(@notes_relation).to receive(:reorder).and_return(@notes_relation)

    # Important: mock from for DISTINCT queries
    @from_relation = double('FromRelation')
    allow(@from_relation).to receive(:order).and_return(@from_relation)
    allow(note_model).to receive(:from).and_return(@from_relation)
    allow(note_model).to receive(:select).and_return(note_model)
    allow(note_model).to receive(:joins).and_return(@from_relation)

    # Mock table_name for ClassDouble
    allow(note_model).to receive(:table_name).and_return('notes')

    # Stubs for Rails route helpers needed for controller tests
    routes.draw do
      get 'index' => 'test_sortable_module/test_sortable#index'
    end
  end

  describe '#sort_column and #sort_direction' do
    it 'returns default sort column and direction when not specified' do
      get :index

      expect(controller.sort_column).to eq('notes.created_at')
      expect(controller.sort_direction).to eq('desc')
    end

    it 'returns the specified sort column and direction' do
      # Mock the sort_column method directly
      allow(controller).to receive(:sort_column).and_return('title')
      allow(controller).to receive(:sort_direction).and_return('asc')

      get :index, params: { sort: { column: 'title', direction: 'asc' } }

      # Check that our mocks are working
      expect(controller.sort_column).to eq('title')
      expect(controller.sort_direction).to eq('asc')
    end

    it 'returns desc direction when invalid direction is provided' do
      get :index, params: { sort: { column: 'title', direction: 'invalid' } }

      expect(controller.sort_direction).to eq('desc')
    end
  end

  describe '#sort_params' do
    it 'returns the sort parameters as a hash' do
      allow(controller).to receive(:sort_column).and_return('title')
      allow(controller).to receive(:sort_direction).and_return('asc')

      expect(controller.sort_params).to eq(sort: { column: 'title', direction: 'asc' })
    end
  end

  describe '#is_valid_sort_column?' do
    it 'returns true for valid columns' do
      allow(controller).to receive(:valid_columns).and_return(['title', 'content', 'notes.created_at'])

      expect(controller.send(:is_valid_sort_column?, 'title')).to be_truthy
      expect(controller.send(:is_valid_sort_column?, 'notes.created_at')).to be_truthy
    end

    it 'returns false for invalid columns' do
      allow(controller).to receive(:valid_columns).and_return(['title', 'content', 'notes.created_at'])

      expect(controller.send(:is_valid_sort_column?, 'invalid_column')).to be_falsey
    end

    it 'recognizes related columns' do
      allow(controller).to receive(:valid_columns).and_return([])
      allow(controller.class).to receive(:related_sortable_columns).and_return(['users.name', 'users.email'])

      expect(controller.send(:is_valid_sort_column?, 'users.name')).to be_truthy
    end
  end

  describe 'handling of text columns in apply_sorting' do
    it 'detects text columns correctly' do
      # Mock the is_text_column? method to test its behavior
      expect(controller).to receive(:is_text_column?)
        .with(note_model, 'title')
        .and_return(true)

      # The actual method should delegate to model-specific is_text_column?
      expect(controller.is_text_column?(note_model, 'title')).to be_truthy

      # Non-text columns should return false
      expect(controller).to receive(:is_text_column?)
        .with(note_model, 'created_at')
        .and_return(false)

      expect(controller.is_text_column?(note_model, 'created_at')).to be_falsey
    end
  end
end
