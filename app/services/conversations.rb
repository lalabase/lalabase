# frozen_string_literal: true

# The switch for conversations (messages between members of one organisation),
# and the namespace for what serves them.
# Entry point: enabled?
#
# Off unless LALABASE_CONVERSATIONS=1 is set in the environment of the
# instance. Asked when something runs, not at boot, and on for the value 1
# only (the rule of Lalabase::Demo): a blanked line or a line meant as "off"
# must not switch it on.
#
# Nothing asks the switch yet. There is no route, no screen and no job it
# could close; the first caller comes with the first route. The models, the
# policy and the personal data export do not ask it and never will: who reads
# a conversation is a rule of the data (Conversation.visible_to), and a rule
# of the data does not hang on the environment.
#
# The switch is for the whole instance. It does not know organisations.
module Conversations
  ENV_FLAG = 'LALABASE_CONVERSATIONS'
  # The only value that switches it on.
  ENABLED_VALUE = '1'

  def self.enabled?(env = ENV)
    env[ENV_FLAG].to_s.strip == ENABLED_VALUE
  end
end
