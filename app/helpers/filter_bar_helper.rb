# frozen_string_literal: true

# Helpers around the ONE filter bar (NeoFilterBarComponent,
# doc/filterleiste_s1_s4_plan.md). Until 07.09.2026 this file also held
# `filter_bar_component_class`, which picked between the rebuilt bar and a
# frozen copy of the old one depending on a per-user preference. The flag, the
# copy and the switch are gone (07.09.2026): two bars meant every change to the
# list head was two changes, and the copy was frozen anyway.
module FilterBarHelper
  # What the menu at the active tab may offer (doc/filterleiste_s5_s8_plan.md,
  # S5): the policy's answers for the ONE active folder. Decided here and not
  # in the component, so the component stays context-free and its spec can
  # pass any answer. Never computed for the whole list: SmartFolderPolicy's
  # per-record checks query shares, and the list is the policy scope's job.
  def filter_bar_view_permissions(folder)
    return {} unless folder

    folder_policy = policy(folder)
    { rename: folder_policy.update?, share: folder_policy.share?, delete: folder_policy.destroy? }
  end
end
