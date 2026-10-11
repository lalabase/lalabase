# frozen_string_literal: true

# app/services/post_update_service.rb

class PostUpdateService
  # Reuse the BaseActor::Result class for consistency
  Result = Actors::BaseActor::Result

  def initialize(ticket, post_params, post_id, current_user, form_params)
    @ticket = ticket
    @post_params = post_params
    @post_id = post_id
    @current_user = current_user
    @form_params = form_params
  end

  def call
    # Initialize the post object outside the transaction
    post_actor = Actors::SavePost.new(ticket: @ticket, params: @post_params, id: @post_id, current_user: @current_user)
    post = post_actor.record

    ActiveRecord::Base.transaction do
      # Save the post
      post_result = post_actor.call

      return post_result unless post_result.success?

      # On success, save documents if form parameters are present
      if @form_params.present?
        docs_actor = Actors::SavePostDocuments.new(post: post, params: @form_params)
        docs_result = docs_actor.call

        # If document saving fails, roll back the entire transaction
        return docs_result unless docs_result.success?
      end

      # Successful return with the post as the resource
      post_result
    end
  rescue StandardError => e
    # Error handling for unexpected errors
    # We return the post object even if it was not saved
    Result.new(
      success: false,
      resource: post,
      errors: [e.message],
      log_message: I18n.t('services.post_update.unexpected_error', error: e.message)
    )
  end
end
