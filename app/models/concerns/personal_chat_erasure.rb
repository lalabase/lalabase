# frozen_string_literal: true

# Erases the chat threads an account owns, for the account-erasure path
# (assistant plan §5.3).
#
# A concern rather than a method, because the erasure has TWO entry points on the
# same table: User::DeletionLifecycle when a person deletes their own account, and
# Admin::User#soft_delete_and_anonymize! when an administrator does it from the
# backend. Those are separate implementations of the same promise, and a promise
# kept in only one of them is the failure mode this file exists to prevent
# (CLAUDE.md, "Admin-Zwilling braucht dasselbe Concern").
#
# Since 2026-08-24 this module is composed into PersonalDataErasure, the single
# erasure entry point, and reached from there through erase_personal_data!. The
# two models include PersonalDataErasure, not this module directly; do not
# include it on its own.
#
# Once a thread belongs to a person it is private content with exactly one
# legitimate reader, and that reader is the account being erased. Destroyed rather
# than nulled: an owner-less personal thread would be readable by nobody and
# deletable by nobody, so nulling would only leave litter.
#
# Neither path ever runs a DELETE — both are soft deletes — so neither the FK nor a
# `dependent: :destroy` on the association would fire. It has to be explicit.
module PersonalChatErasure
  private

  # `destroy_all`, not `delete_all`: there is no FK from chatposts to chats, so a
  # bulk delete would orphan every message in the thread.
  #
  # ONLY owned threads. Until S4-T1 the ticket thread was a SHARED lane without an
  # owner and had to be excluded here explicitly; that surface is dissolved. An owned
  # thread is the owner's own conversation (plan §6.1) once the §5.4 sweep has removed
  # the shared-era project threads: the backfill hands those to their FIRST asker,
  # and until the sweep such a thread can still hold a colleague's questions (the
  # same caveat Neo::Chat::MessageComponent#owner_viewer? carries).
  #
  # without_tenant because a person spans organisations and an erasure is not
  # tenant-scoped.
  def erase_personal_chats!
    ActsAsTenant.without_tenant do
      Chat.where(user_id: id).destroy_all
    end
  end
end
