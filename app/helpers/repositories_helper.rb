# frozen_string_literal: true

# Single source for the two repo-page authorisation checks the UI needs OUTSIDE
# the repo controller itself: the settings card, the documentation empty-states /
# index header and the chat empty-state hint all decide what to show from these.
#
# Why a helper and not `policy(project)` (as ChatsHelper does): Pundit infers the
# policy from the record's CLASS, so `policy(project)` resolves to ProjectPolicy —
# never ProjectRepositoryPolicy. We therefore instantiate the repo policy
# explicitly. Keeping it here means a future gating change touches one place and
# no view re-derives the (deliberately non-obvious) chats-OR-documentation rule.
module RepositoriesHelper
  # Canonical documentation round-trip marker. SINGLE source shared by the repo
  # controller (sanitising allowlist + post-connect redirect) AND the views that
  # produce the CTA links / read the back-link — so a rename can never drift the
  # producers and the consumer apart. Use #documentation_origin in views.
  ORIGIN_DOCUMENTATION = 'documentation'

  # The documentation origin value for use in views (link params + back-link
  # comparison) instead of a bare 'documentation' literal.
  def documentation_origin
    ORIGIN_DOCUMENTATION
  end

  # May the user connect/disconnect/rotate a repo? (ProjectRepositoryPolicy#create?)
  # Drives every write affordance: connect buttons, the "manage" CTA, the
  # persistent doc-index link.
  def can_manage_repositories?(project)
    ProjectRepositoryPolicy.new(current_user, project).create?
  end

  # May the user at least see the repo list? (ProjectRepositoryPolicy#index?)
  # A superset of #can_manage_repositories? — used for the read-only "view" CTA.
  def can_view_repositories?(project)
    ProjectRepositoryPolicy.new(current_user, project).index?
  end
end
