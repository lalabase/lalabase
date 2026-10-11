# frozen_string_literal: true

# The operator identity lives in SystemSetting rows (LegalIdentity). A spec that asserts a
# legal link or the operator credit stores known values; the transaction rolls them back.
#
#   describe 'something', legal_identity: { privacy_page_url: 'https://public.example/privacy' }
#   with_legal_identity(operator_name: 'Operator') { ... }   # restores the values afterwards
module LegalIdentityHelpers
  def store_legal_identity(values = {})
    identity = LegalIdentity.new(values)
    raise ArgumentError, identity.errors.full_messages.to_sentence unless identity.save
  end

  def with_legal_identity(**values)
    previous = LegalIdentity.load
    store_legal_identity(values)
    yield
  ensure
    store_legal_identity(LegalIdentity::ATTRIBUTES.index_with { |attribute| previous.public_send(attribute) }) if previous
  end
end

RSpec.configure do |config|
  config.include LegalIdentityHelpers

  config.before(:each, :legal_identity) do |example|
    store_legal_identity(example.metadata[:legal_identity])
  end
end
