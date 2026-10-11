# frozen_string_literal: true

# ⚠️ EMPTY SINCE projekt_chat_abbau, and kept for one release only.
#
# This concern carried the per-organisation beta gate of the PROJECT-aware chat:
# `organisations.project_chat_enabled` (renamed to `code_indexing_enabled` in step 4),
# asked above the per-user/project
# `area_access?` permissions. That surface is gone, and the flag it read is not the
# surface flag at all — it decides whether the code index is built (see
# doc/projekt_chat_abbau_plan.md, "The trap"), which is why step 4 renames the column
# rather than dropping it.
#
# ChatPolicy no longer needs anything from here: its gate is the §13-2 assistant pair,
# which it owns itself. The include stays for the length of this cut so the diff of the
# policy is readable; remove both in step 4, when the column gets its real name.
#
# It previously also held ScopeResolution, a shared "beta gate plus chats-area scoping"
# resolve. That had been unused since S1 (ChatPolicy carries its own, because this one
# returned scope.all for an account_admin before any owner filter could apply, R-H1)
# and it went with the surface: a helper whose only shape is the removed one is not a
# spare part, it is a remnant.
module ChatFeatureGated
end
