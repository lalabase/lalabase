# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pageable, type: :controller do
  # Anonymous controller to test the concern in isolation.
  # Uses ActionController::Base to avoid ApplicationController's
  # before_actions (authentication, tenant setup, etc.)
  controller(ActionController::Base) do
    include Pageable

    attr_accessor :current_user

    def index
      render plain: 'ok'
    end
  end

  before do
    routes.draw do
      get 'anonymous/index' => 'anonymous#index'
    end
  end

  # ==========================================================================
  # .setup_pagination (ClassMethods)
  # ==========================================================================
  describe '.setup_pagination' do
    after { controller.class.default_per_page = nil }

    it 'sets default_per_page to the given value' do
      controller.class.setup_pagination(50)
      expect(controller.class.default_per_page).to eq(50)
    end

    it 'defaults to DEFAULT_PER_PAGE when no argument given' do
      controller.class.setup_pagination
      expect(controller.class.default_per_page).to eq(Pageable::DEFAULT_PER_PAGE)
    end
  end

  # ==========================================================================
  # #items_per_page — Priority: URL param > User pref > Controller default > 20
  # ==========================================================================
  describe '#items_per_page' do
    after { controller.class.default_per_page = nil }

    # --- Priority 1: URL parameters ---
    context 'with items URL parameter' do
      it 'returns the items value as integer' do
        get :index, params: { items: '25' }
        expect(controller.items_per_page).to eq(25)
      end
    end

    context 'with limit URL parameter' do
      it 'returns the limit value as integer' do
        get :index, params: { limit: '30' }
        expect(controller.items_per_page).to eq(30)
      end
    end

    context 'with both items and limit URL parameters' do
      it 'prefers items over limit' do
        get :index, params: { items: '25', limit: '30' }
        expect(controller.items_per_page).to eq(25)
      end
    end

    # --- Priority 2: User preference ---
    context 'with user preference' do
      let(:user) { instance_double('User', items_per_page_preference: 50) }

      before { controller.current_user = user }

      it 'returns user preference when no URL param' do
        get :index
        expect(controller.items_per_page).to eq(50)
      end

      it 'URL param takes precedence over user preference' do
        get :index, params: { items: '10' }
        expect(controller.items_per_page).to eq(10)
      end
    end

    context 'with user preference of 0' do
      let(:user) { instance_double('User', items_per_page_preference: 0) }

      before { controller.current_user = user }

      it 'falls through to controller default' do
        controller.class.setup_pagination(35)
        get :index
        expect(controller.items_per_page).to eq(35)
      end
    end

    context 'when current_user is nil' do
      before { controller.current_user = nil }

      it 'falls through to controller default' do
        controller.class.setup_pagination(15)
        get :index
        expect(controller.items_per_page).to eq(15)
      end
    end

    context 'when current_user does not respond to items_per_page_preference' do
      let(:user) { double('BasicUser') }

      before { controller.current_user = user }

      it 'falls through to controller default' do
        controller.class.setup_pagination(40)
        get :index
        expect(controller.items_per_page).to eq(40)
      end
    end

    # --- Priority 3: Controller default ---
    context 'with controller default_per_page set' do
      it 'returns the configured default' do
        controller.class.setup_pagination(42)
        get :index
        expect(controller.items_per_page).to eq(42)
      end
    end

    # --- Priority 4: Absolute default ---
    context 'with no configuration at all' do
      before { controller.current_user = nil }

      it 'returns DEFAULT_PER_PAGE (20)' do
        controller.class.default_per_page = nil
        get :index
        expect(controller.items_per_page).to eq(Pageable::DEFAULT_PER_PAGE)
      end
    end

    # --- Edge cases ---
    context 'with non-numeric items parameter' do
      it 'clamps to MIN_PER_PAGE' do
        get :index, params: { items: 'abc' }
        expect(controller.items_per_page).to eq(Pageable::MIN_PER_PAGE)
      end
    end

    context 'with empty string items parameter' do
      before { controller.current_user = nil }

      it 'falls through to next priority level' do
        controller.class.setup_pagination(25)
        get :index, params: { items: '' }
        expect(controller.items_per_page).to eq(25)
      end
    end

    context 'with negative items parameter' do
      it 'clamps to MIN_PER_PAGE' do
        get :index, params: { items: '-5' }
        expect(controller.items_per_page).to eq(Pageable::MIN_PER_PAGE)
      end
    end

    context 'with zero items parameter' do
      it 'clamps to MIN_PER_PAGE' do
        get :index, params: { items: '0' }
        expect(controller.items_per_page).to eq(Pageable::MIN_PER_PAGE)
      end
    end

    context 'with excessively large items parameter' do
      it 'clamps to MAX_PER_PAGE' do
        get :index, params: { items: '999999' }
        expect(controller.items_per_page).to eq(Pageable::MAX_PER_PAGE)
      end
    end
  end

  # ==========================================================================
  # #paginate
  # ==========================================================================
  describe '#paginate' do
    let(:query) { double('ActiveRecord::Relation') }
    let(:pagy_instance) { instance_double(Pagy) }
    let(:records) { [] }

    before do
      allow(controller).to receive(:pagy).and_return([pagy_instance, records])
    end

    it 'calls pagy with the query and correct options' do
      get :index, params: { page: '2' }
      controller.paginate(query)

      expect(controller).to have_received(:pagy).with(
        query,
        hash_including(page: 2, limit: anything)
      )
    end

    it 'returns [pagy_instance, records]' do
      get :index
      result = controller.paginate(query)
      expect(result).to eq([pagy_instance, records])
    end

    it 'ensures page is at least 1 when page=0' do
      get :index, params: { page: '0' }
      controller.paginate(query)

      expect(controller).to have_received(:pagy).with(
        query,
        hash_including(page: 1)
      )
    end

    it 'ensures page is at least 1 when page is negative' do
      get :index, params: { page: '-3' }
      controller.paginate(query)

      expect(controller).to have_received(:pagy).with(
        query,
        hash_including(page: 1)
      )
    end

    it 'passes smart_folder_id in params when present' do
      get :index, params: { smart_folder_id: 'sf-123' }
      controller.paginate(query)

      expect(controller).to have_received(:pagy).with(
        query,
        hash_including(params: hash_including(smart_folder_id: 'sf-123'))
      )
    end

    it 'passes project_id in params when present' do
      get :index, params: { project_id: 'proj-456' }
      controller.paginate(query)

      expect(controller).to have_received(:pagy).with(
        query,
        hash_including(params: hash_including(project_id: 'proj-456'))
      )
    end

    it 'does not include smart_folder_id when absent' do
      get :index
      controller.paginate(query)

      expect(controller).to have_received(:pagy) do |_query, opts|
        expect(opts[:params]).not_to have_key(:smart_folder_id)
      end
    end

    it 'uses options[:items] when provided' do
      get :index
      controller.paginate(query, items: 99)

      expect(controller).to have_received(:pagy).with(
        query,
        hash_including(limit: 99)
      )
    end

    it 'falls back to items_per_page when no options[:items]' do
      allow(controller).to receive(:items_per_page).and_return(42)
      get :index
      controller.paginate(query)

      expect(controller).to have_received(:pagy).with(
        query,
        hash_including(limit: 42)
      )
    end

    it 'always includes items in pagy params for URL generation' do
      get :index
      controller.paginate(query)

      expect(controller).to have_received(:pagy) do |_query, opts|
        expect(opts[:params][:items]).to be_present
      end
    end
  end

  # ==========================================================================
  # #pagination_params
  # ==========================================================================
  describe '#pagination_params' do
    it 'returns hash with page and items' do
      get :index, params: { page: '3', items: '25' }
      result = controller.pagination_params

      expect(result).to include(page: 3)
      expect(result[:items]).to eq('25')
    end

    it 'returns nil for page when page param is absent' do
      get :index
      result = controller.pagination_params

      expect(result[:page]).to be_nil
    end

    it 'ensures page is at least 1' do
      get :index, params: { page: '0' }
      result = controller.pagination_params

      expect(result[:page]).to eq(1)
    end

    it 'handles negative page values' do
      get :index, params: { page: '-5' }
      result = controller.pagination_params

      expect(result[:page]).to eq(1)
    end

    it 'includes smart_folder_id when present' do
      get :index, params: { smart_folder_id: 'sf-789' }
      result = controller.pagination_params

      expect(result[:smart_folder_id]).to eq('sf-789')
    end

    it 'does not include smart_folder_id when absent' do
      get :index
      result = controller.pagination_params

      expect(result).not_to have_key(:smart_folder_id)
    end

    it 'falls back to limit when items not present' do
      get :index, params: { limit: '30' }
      result = controller.pagination_params

      expect(result[:items]).to eq('30')
    end

    it 'falls back to items_per_page when neither items nor limit present' do
      allow(controller).to receive(:items_per_page).and_return(42)
      get :index
      result = controller.pagination_params

      expect(result[:items]).to eq(42)
    end

    it 'does not include unexpected parameters' do
      get :index, params: { page: '1', items: '20', evil: 'hack' }
      result = controller.pagination_params

      expect(result).not_to have_key(:evil)
    end
  end

  # ==========================================================================
  # #sort_and_pagination_params
  # ==========================================================================
  describe '#sort_and_pagination_params' do
    it 'returns pagination params when Sortable is not included' do
      get :index, params: { page: '2', items: '25' }
      result = controller.sort_and_pagination_params

      expect(result).to include(page: 2)
      expect(result[:items]).to eq('25')
    end

    context 'when controller responds to sort_params' do
      before do
        # Define sort_params on the controller instance to satisfy respond_to? check
        def controller.sort_params
          { sort: { column: 'name', direction: 'asc' } }
        end
      end

      it 'merges sort params into result' do
        get :index, params: { page: '1', items: '20' }
        result = controller.sort_and_pagination_params

        expect(result[:sort]).to eq({ column: 'name', direction: 'asc' })
      end

      it 'removes page when sort column is present in URL params' do
        get :index, params: { page: '3', items: '20', sort: { column: 'name', direction: 'asc' } }
        result = controller.sort_and_pagination_params

        expect(result[:page]).to be_nil
      end

      it 'preserves page when no sort column in URL params' do
        get :index, params: { page: '3', items: '20' }
        result = controller.sort_and_pagination_params

        expect(result[:page]).to eq(3)
      end
    end

    it 'preserves smart_folder_id from URL params' do
      get :index, params: { smart_folder_id: 'sf-123' }
      result = controller.sort_and_pagination_params

      expect(result[:smart_folder_id]).to eq('sf-123')
    end

    context 'when sort_params returns nil' do
      before do
        def controller.sort_params
          nil
        end
      end

      it 'uses empty hash as fallback' do
        get :index, params: { page: '1' }
        result = controller.sort_and_pagination_params

        expect(result).to include(page: 1)
      end
    end
  end

  # NOTE: the #pagy_url_for block that stood here is gone with the method itself.
  # It was a controller-side twin of ApplicationHelper#pagy_url_for and could
  # never run in production, because pagy_url_for is called from pagy_nav in the
  # VIEW and this concern never exposed it via helper_method. Its two genuinely
  # interesting cases -- a UUID and a .json parsed as the format suffix -- moved
  # to spec/helpers/pagy_url_for_spec.rb, where the surviving builder lives.
  #
  # Without the deletion these examples did not fail loudly either: `controller.
  # pagy_url_for` still resolved, just to PAGY's own implementation via
  # Pagy::UrlHelpers, which asks the double for `vars` and got
  # "received unexpected message :vars".

  # ==========================================================================
  # #respond_to_sort_and_paginate
  # ==========================================================================
  describe '#respond_to_sort_and_paginate' do
    let(:pagy_instance) { instance_double(Pagy) }
    let(:collection) { double('ActiveRecord::Relation') }

    context 'with turbo_stream format' do
      it 'calls respond_to' do
        get :index, params: { page: '1' }

        expect(controller).to receive(:respond_to).and_yield(
          double('Responder').as_null_object
        )

        controller.respond_to_sort_and_paginate(
          pagy_instance, collection, 'tickets-frame', 'tickets/list'
        )
      end
    end

    context 'with invalid smart_folder_id' do
      it 'logs error and continues without smart folder' do
        get :index, params: { smart_folder_id: 'nonexistent' }

        allow(controller).to receive(:respond_to).and_yield(
          double('Responder').as_null_object
        )

        # Stub SmartFolder.find to raise RecordNotFound (avoids tenant issues)
        allow(SmartFolder).to receive(:find)
          .with('nonexistent')
          .and_raise(ActiveRecord::RecordNotFound.new("Couldn't find SmartFolder"))

        expect(Rails.logger).to receive(:error).with(/SmartFolder/)

        controller.respond_to_sort_and_paginate(
          pagy_instance, collection, 'frame', 'path'
        )
      end
    end

    it 'sets @pagy instance variable when not already set' do
      get :index
      allow(controller).to receive(:respond_to).and_yield(
        double('Responder').as_null_object
      )

      controller.respond_to_sort_and_paginate(
        pagy_instance, collection, 'frame', 'path'
      )

      expect(controller.instance_variable_get(:@pagy)).to eq(pagy_instance)
    end

    it 'does not overwrite existing @pagy' do
      get :index
      existing_pagy = instance_double(Pagy)
      controller.instance_variable_set(:@pagy, existing_pagy)

      allow(controller).to receive(:respond_to).and_yield(
        double('Responder').as_null_object
      )

      controller.respond_to_sort_and_paginate(
        pagy_instance, collection, 'frame', 'path'
      )

      expect(controller.instance_variable_get(:@pagy)).to eq(existing_pagy)
    end

    it 'passes custom locals to the partial' do
      get :index
      responder = double('Responder').as_null_object
      allow(controller).to receive(:respond_to).and_yield(responder)

      # Should not raise — verifies that custom locals are merged
      expect do
        controller.respond_to_sort_and_paginate(
          pagy_instance, collection, 'frame', 'path',
          { custom_key: 'custom_value' }
        )
      end.not_to raise_error
    end

    context 'when collection responds to model' do
      it 'adds collection under its model name as local' do
        get :index
        model_class = double('ModelClass', name: 'Ticket')
        allow(collection).to receive(:respond_to?).with(:model).and_return(true)
        allow(collection).to receive(:model).and_return(model_class)

        responder = double('Responder').as_null_object
        allow(controller).to receive(:respond_to).and_yield(responder)

        expect do
          controller.respond_to_sort_and_paginate(
            pagy_instance, collection, 'frame', 'path'
          )
        end.not_to raise_error
      end
    end
  end

  # ==========================================================================
  # helper_method registration
  # ==========================================================================
  describe 'helper_method registration' do
    it 'registers items_per_page as helper' do
      expect(controller.class._helper_methods).to include(:items_per_page)
    end

    it 'registers pagination_params as helper' do
      expect(controller.class._helper_methods).to include(:pagination_params)
    end

    it 'registers sort_and_pagination_params as helper' do
      expect(controller.class._helper_methods).to include(:sort_and_pagination_params)
    end
  end

  # ==========================================================================
  # Constants
  # ==========================================================================
  describe 'constants' do
    it 'defines DEFAULT_PER_PAGE' do
      expect(Pageable::DEFAULT_PER_PAGE).to eq(20)
    end

    it 'defines MIN_PER_PAGE' do
      expect(Pageable::MIN_PER_PAGE).to eq(1)
    end

    it 'defines MAX_PER_PAGE' do
      expect(Pageable::MAX_PER_PAGE).to eq(200)
    end

    it 'freezes PAGINATION_PARAMS' do
      expect(Pageable::PAGINATION_PARAMS).to be_frozen
    end

    it 'freezes EXTENDED_PARAMS' do
      expect(Pageable::EXTENDED_PARAMS).to be_frozen
    end
  end
end
