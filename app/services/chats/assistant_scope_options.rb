# frozen_string_literal: true

# Which projects the assistant's scope chip may offer (S3a T5, plan §9.3).
# Entry point: call
#
# ONE owner, because the answer is needed twice and the two must not drift: the
# chip renders this list, and AssistantChatsController#update refuses anything
# outside it. A chip that offers more than the write path accepts produces a dead
# option; a write path that accepts more than the chip offers is a way to pin a
# thread to a project the user cannot see.
#
# Active projects only -- archived ones are out of the assistant's reach by
# decision (T3, confirmed for T5), so offering them would promise a narrowing that
# Tools::Scope then refuses to honour.
#
# The rights question is the app's usual one (ProjectPolicy::Scope), not the
# assistant's per-area reach: the chip picks a PROJECT, and what may be read
# inside it stays the per-area gate's business, unchanged.
module Chats
  class AssistantScopeOptions
    def self.call(user:, organisation:)
      new(user: user, organisation: organisation).call
    end

    def initialize(user:, organisation:)
      @user = user
      @organisation = organisation
    end

    def call
      return Project.none if @user.nil? || @organisation.nil?

      ProjectPolicy::Scope.new(@user, @organisation.projects.active).resolve.order(:name)
    end

    # Does this id name an offerable project? The write path's whole validation.
    def includes?(project_id)
      return true if project_id.blank? # clearing the chip is always allowed

      call.exists?(id: project_id)
    end
  end
end
