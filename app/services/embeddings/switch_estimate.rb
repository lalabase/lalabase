# frozen_string_literal: true

# KI-Pakete P4b (doc/ki_pakete_p4_plan.md E7) — the rough size and price of the
# re-embedding a package switch sets off, computed BEFORE the switch starts.
module Embeddings
  # Estimates how much corpus a package switch has to re-embed and what that
  # costs in credits, for the consequence dialog (E7).
  #
  # An ESTIMATE, deliberately, and it says so on the surface it feeds. Two
  # reasons, both structural rather than sloppiness:
  #
  #   * Tokens are approximated as characters / CHARS_PER_TOKEN. A binding number
  #     would need the real tokenizer over the whole corpus, which costs about as
  #     much as the reindex it is pricing (E7).
  #   * The corpus is counted WHOLE, while the reindexer skips records that
  #     already have a readable row in the target space
  #     (OrganisationReindexer#stale). So this is an UPPER bound: the real run
  #     tends to be smaller, never larger. Asking the anti-join instead would be
  #     four correlated scans on a page the customer opens by hand — the very
  #     cost §5 Falle 1 keeps SpaceAlignment out of customer surfaces for.
  #
  # The four tables come from OrganisationReindexer::TARGETS rather than a list of
  # their own: what the switch re-embeds is that constant's business, and a second
  # copy here would price a corpus the run does not actually process.
  #
  # Entry point: call
  class SwitchEstimate
    # E7's rule of thumb, ~±30 % across languages and code. A constant rather than
    # a tokenizer call — see the class note.
    CHARS_PER_TOKEN = 4

    # Headroom a caller should demand before calling this estimate "covered".
    #
    # It lives HERE, next to the imprecision it compensates, rather than at the
    # consumer: CHARS_PER_TOKEN is the ±30 % rule of thumb, and only ONE of this
    # class's two error sources points downwards (the reindexer's skip logic). The
    # token approximation runs both ways — CodeSymbol#signature is code, which
    # tokenises denser than four characters per token. Whoever changes the
    # approximation has to weigh the margin in the same breath.
    SAFETY_MARGIN = 1.3

    # @param records [Integer] source rows across the four embedded tables
    # @param characters [Integer] their total source-text length
    # @param tokens [Integer] characters / CHARS_PER_TOKEN, rounded up
    # @param credits [Integer] what the run would book at the DOCUMENT_INDEXING tariff
    Result = Struct.new(:records, :characters, :tokens, :credits, keyword_init: true)

    # How long a quoted estimate stays good enough to reuse. The number is rough by
    # construction (see the class note), so minutes of staleness cost nothing in
    # meaning — while recomputing costs four full-corpus aggregates, and
    # `SUM(LENGTH(text))` has to detoast and decompress every row it touches. This
    # runs on a GET a customer can sit on F5 with, against the shared production
    # database (#437 review).
    CACHE_TTL = 10.minutes

    def self.call(organisation:)
      Rails.cache.fetch(cache_key(organisation), expires_in: CACHE_TTL) do
        new(organisation: organisation).call
      end
    end

    # The UNCACHED computation. For callers that must see the corpus exactly as it
    # is now — and for examples that assert on a corpus they just built, which a
    # cached zero from an earlier example would otherwise answer.
    def self.call!(organisation:)
      new(organisation: organisation).call
    end

    def self.cache_key(organisation)
      ['embeddings/switch_estimate', organisation.id]
    end

    def initialize(organisation:)
      @organisation = organisation
    end

    # @return [Result]
    def call
      records = 0
      characters = 0

      # Same tenant frame as OrganisationReindexer#call: the four models are
      # tenant-scoped, and this service is also reachable from contexts whose
      # current tenant is not this org.
      ActsAsTenant.with_tenant(@organisation) do
        OrganisationReindexer::TARGETS.each do |target|
          count, length = measure(target)
          records += count
          characters += length
        end
      end

      tokens = (characters.to_f / CHARS_PER_TOKEN).ceil
      Result.new(records: records, characters: characters, tokens: tokens, credits: credits_for(tokens))
    end

    private

    # ONE aggregate query per table, count and length together: they answer the
    # same question about the same rows, and two queries could only ever disagree.
    # The explicit organisation_id filter mirrors OrganisationReindexer#scope.
    #
    # SUM answers NULL for an empty table and skips NULL texts, so a row without
    # source text counts as a RECORD with no characters — which is what it is.
    # #to_i carries that; a COALESCE here would be unobservable extra SQL.
    # @return [Array(Integer, Integer)] [row count, total source-text characters]
    def measure(target)
      klass = target[:model].constantize
      column = "#{klass.quoted_table_name}.#{klass.connection.quote_column_name(target[:text])}"
      count, length = klass.where(organisation_id: @organisation.id)
                           .pick(Arel.sql('COUNT(*)'), Arel.sql("SUM(LENGTH(#{column}))"))
      [count.to_i, length.to_i]
    end

    # The SAME tariff call the reindexer books with, including its zero-token rule
    # (OrganisationReindexer#record_run_usage writes no row at all for a run with
    # no tokens). Without that guard an empty corpus would be quoted at 1 credit —
    # ActionRegistry.credits_for floors every PRICED call at one started block —
    # and the dialog would name a price no run will ever charge.
    def credits_for(tokens)
      return 0 if tokens.zero?

      ::Lalabase::Llm::ActionRegistry.credits_for(
        ::Lalabase::Llm::ActionRegistry::DOCUMENT_INDEXING, tokens: tokens
      )
    end
  end
end
