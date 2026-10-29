# frozen_string_literal: true

require 'rails_helper'

# Feinschliff C: the objects an answer NAMES become links.
#
# The whitelist is the answer's own citations, never the text. Two reasons, both
# load-bearing:
#   * a number in prose is ambiguous org-wide (ticket numbers are unique per
#     PROJECT), so "#187" alone addresses nothing,
#   * the citations are already gated for this viewer
#     (MessageComponent#visible_citations), so linking only what is cited means the
#     prose cannot name an object the source list is hiding.
#
# Everything here works on the SANITISED html the chat renders, and produces html
# again — the anchors are built here, after the sanitiser, because the allowlist
# has no data attributes and the turbo escape is one.
RSpec.describe Lalabase::CitationInlineLinks do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def ticket_cite(number: 42, id: SecureRandom.uuid, title: 'Login bug')
    { 'type' => 'ticket', 'area' => 'tickets', 'id' => id, 'project_id' => project.id,
      'number' => number, 'title' => title }
  end

  def note_cite(title: 'Kickoff-Protokoll', id: SecureRandom.uuid)
    { 'type' => 'note', 'area' => 'notes', 'id' => id, 'project_id' => project.id, 'title' => title }
  end

  def apply(html, citations)
    described_class.apply(html: html, citations: citations, organisation: organisation, project: project)
  end

  describe 'tickets by number' do
    it 'links a bare #number' do
      cite = ticket_cite(number: 42)
      result = apply('<p>Das steht in #42.</p>', [cite])

      # The address comes from the route helper, not from a hand-spelled prefix:
      # this is the SAME builder the source list uses (Lalabase::CitationLink).
      expected = Rails.application.routes.url_helpers
                      .organisation_project_ticket_path(organisation, project, cite['id'])
      expect(result).to include(%(<a href="#{expected}"))
      expect(result).to include('>#42</a>')
    end

    it 'links the spelled-out forms in both languages' do
      ['<p>Siehe Aufgabe 42 dazu.</p>', '<p>See ticket #42 there.</p>', '<p>Das Ticket 42 sagt es.</p>']
        .each do |html|
          expect(apply(html, [ticket_cite(number: 42)])).to include('</a>')
        end
    end

    it 'does NOT match a longer number that merely starts with it' do
      expect(apply('<p>Siehe #420 dazu.</p>', [ticket_cite(number: 42)])).not_to include('</a>')
    end

    it 'does NOT match a number glued to a word' do
      expect(apply('<p>Der Commit abc#42 ist gemeint.</p>', [ticket_cite(number: 42)])).not_to include('</a>')
    end
  end

  describe 'everything else by its exact title' do
    it 'links a note title at word boundaries' do
      cite = note_cite(title: 'Kickoff-Protokoll')
      result = apply('<p>Das Kickoff-Protokoll nennt drei Punkte.</p>', [cite])

      expect(result).to include(%(/notes/#{cite['id']}"))
      expect(result).to include('>Kickoff-Protokoll</a>')
    end

    it 'does not link a title that is merely PART of a longer word' do
      expect(apply('<p>Im Kickoff-Protokollentwurf steht es.</p>', [note_cite(title: 'Kickoff-Protokoll')]))
        .not_to include('</a>')
    end

    # People S3: a person has a name rather than a title, and the answer names the person
    # it found ("Ansprechpartnerin ist Doris Dienstleister").
    it 'links the name of a cited person to the people page' do
      cite = { 'type' => 'person', 'area' => 'people', 'id' => 'pid', 'name' => 'Doris Dienstleister' }
      result = apply('<p>Ansprechpartnerin ist Doris Dienstleister.</p>', [cite])

      href = Rails.application.routes.url_helpers.organisation_people_path(organisation, person_id: 'pid')
      expect(result).to include(%(href="#{href}"))
      expect(result).to include('>Doris Dienstleister</a>')
    end

    # Category 3: n-1 / n / n+1 at MIN_TITLE_LENGTH, driven from the constant.
    # A test with a three-character title against a seventeen-character title
    # survives any shift of the boundary; only these three examples die when
    # someone flips `<` and `<=` or touches the number.
    describe 'the shortest title worth looking for' do
      def title_of(length) = ('Zyxwvutsrq' * 2)[0, length]

      it 'ignores a title one character BELOW the minimum' do
        title = title_of(described_class::MIN_TITLE_LENGTH - 1)

        expect(apply("<p>Der #{title} war lang.</p>", [note_cite(title: title)])).not_to include('</a>')
      end

      it 'links a title of EXACTLY the minimum length' do
        title = title_of(described_class::MIN_TITLE_LENGTH)

        expect(apply("<p>Der #{title} war lang.</p>", [note_cite(title: title)])).to include('</a>')
      end

      it 'links a title one character ABOVE the minimum' do
        title = title_of(described_class::MIN_TITLE_LENGTH + 1)

        expect(apply("<p>Der #{title} war lang.</p>", [note_cite(title: title)])).to include('</a>')
      end

      # The TRIMMED title is measured: a title of three characters and four
      # spaces is a three-character title.
      it 'measures the trimmed title, not the padding around it' do
        short = title_of(described_class::MIN_TITLE_LENGTH - 1)

        expect(apply("<p>Der #{short} war lang.</p>", [note_cite(title: "  #{short}  ")]))
          .not_to include('</a>')
      end
    end

    it 'matches a title containing regex metacharacters literally' do
      cite = note_cite(title: 'Preise (2026) [Entwurf]')
      result = apply('<p>Siehe Preise (2026) [Entwurf] dazu.</p>', [cite])

      expect(result).to include(%(/notes/#{cite['id']}"))
    end
  end

  describe 'where it must not reach' do
    # Category 2: one cell per blocked zone, iterated from the constant. A
    # shared example for code and pre would stay green if one of the two dropped
    # out of SKIP_ANCESTORS.
    it 'leaves the text inside EVERY skipped ancestor alone' do
      expect(described_class::SKIP_ANCESTORS).not_to be_empty

      described_class::SKIP_ANCESTORS.each do |tag|
        html = "<p>Siehe <#{tag}>#42</#{tag}> dazu.</p>"
        # COUNT anchors, do not check for '</a>': for the <a> zone there is already one
        # in the source HTML, and the naive check would be red there without a bug.
        before = html.scan('<a').size

        expect(apply(html, [ticket_cite(number: 42)]).scan('<a').size).to eq(before),
                                                                          "a number inside <#{tag}> was linked"
      end
    end

    it 'still links the same number OUTSIDE those zones (flow anchor)' do
      expect(apply('<p>Siehe #42 dazu.</p>', [ticket_cite(number: 42)])).to include('</a>')
    end

    it 'leaves an existing link alone instead of nesting one inside it' do
      html = '<p><a href="https://example.com">#42</a></p>'
      result = apply(html, [ticket_cite(number: 42)])

      expect(result.scan('<a ').size).to eq(1)
      expect(result).to include('https://example.com')
    end

    # R1 (2026-08-31): every mention links. First-mention-only was the designed
    # behaviour of #624 and read as "sometimes linked, sometimes not" — the very
    # complaint that triggered the revision. The in-app help changed with it.
    it 'links EVERY mention of one object' do
      result = apply('<p>#42 und nochmal #42 und #42.</p>', [ticket_cite(number: 42)])

      expect(result.scan('</a>').size).to eq(3)
    end

    it 'links two mentions split across two paragraphs' do
      result = apply('<p>Erst #42.</p><p>Dann wieder #42.</p>', [ticket_cite(number: 42)])

      expect(result.scan('</a>').size).to eq(2)
    end

    it 'links a time report nowhere: it has no page, it has a panel' do
      cite = { 'type' => 'time_report', 'area' => 'time_sessions', 'id' => "#{project.id}:abc",
               'project_id' => project.id, 'title' => project.name, 'filters' => {} }

      expect(apply("<p>Die Auswertung für #{project.name} ergibt 12 Stunden.</p>", [cite]))
        .not_to include('</a>')
    end

    it 'links nothing for the code layer' do
      cite = { 'type' => 'capability', 'id' => SecureRandom.uuid, 'name' => 'Notifications' }
      expect(apply('<p>Die Capability Notifications kann das.</p>', [cite])).not_to include('</a>')
    end

    it 'returns the html untouched when there is nothing to link' do
      html = '<p>Eine Antwort ganz ohne Quellen.</p>'
      expect(apply(html, [])).to eq(html)
    end

    it 'links nothing without an organisation, because there is no address to build' do
      result = described_class.apply(html: '<p>Siehe #42.</p>', citations: [ticket_cite(number: 42)],
                                     organisation: nil, project: project)
      expect(result).not_to include('</a>')
    end
  end

  describe 'safety' do
    it 'carries the turbo escape, like every other link out of the chat frame' do
      result = apply('<p>Siehe #42.</p>', [ticket_cite(number: 42)])
      expect(result).to include('data-turbo-frame="_top"')
    end

    it 'escapes the text it wraps and the text around it' do
      cite = ticket_cite(number: 42)
      # The html arrives sanitised, so `<` in the prose is already an entity. What
      # must not happen is that this step decodes it back into markup.
      result = apply('<p>5 &lt; 6, siehe #42 &amp; folgende.</p>', [cite])

      expect(result).to include('&lt; 6')
      expect(result).to include('&amp; folgende')
      expect(result).not_to include('<script')
    end

    it 'cannot be talked into markup by a citation title' do
      cite = note_cite(title: '<script>alert(1)</script>')
      result = apply('<p>Der Titel &lt;script&gt;alert(1)&lt;/script&gt; steht hier.</p>', [cite])

      expect(result).not_to include('<script>')
    end

    it 'returns a String flagged html_safe, since the caller renders it raw' do
      expect(apply('<p>Siehe #42.</p>', [ticket_cite(number: 42)])).to be_html_safe
    end
  end

  # Review findings for #624.
  describe 'when one wording could mean two things' do
    it 'links NEITHER ticket when two projects both have a #42' do
      other_project = create(:project, organisation: organisation)
      here = ticket_cite(number: 42)
      there = ticket_cite(number: 42).merge('project_id' => other_project.id, 'id' => SecureRandom.uuid)

      result = apply('<p>In #42 steht A. In #42 steht B.</p>', [here, there])

      # A wrong link is worse than text: the sentence is about ONE of them and the
      # array order has nothing to do with which. Flow anchor: alone, each links.
      expect(result).not_to include('</a>')
      expect(apply('<p>In #42 steht A.</p>', [here])).to include('</a>')
    end

    it 'is not decided by the order the citations happen to arrive in' do
      other_project = create(:project, organisation: organisation)
      here = ticket_cite(number: 42)
      there = ticket_cite(number: 42).merge('project_id' => other_project.id, 'id' => SecureRandom.uuid)

      expect(apply('<p>In #42 steht A.</p>', [here, there]))
        .to eq(apply('<p>In #42 steht A.</p>', [there, here]))
    end

    it 'links every mention to ONE address when a ticket is cited with its own comments' do
      ticket = ticket_cite(number: 42)
      comment = { 'type' => 'post', 'area' => 'tickets', 'id' => SecureRandom.uuid,
                  'project_id' => project.id, 'ticket_id' => ticket['id'], 'ticket_number' => 42 }

      # Three citations, one source, one address (PR B). Since R1 every mention is
      # a link — what the collapse must still guarantee is that all of them carry
      # the SAME address instead of fighting over the matches.
      result = apply('<p>#42 sagt das, und #42 noch mal, und #42 zum dritten.</p>',
                     [ticket, comment, comment.merge('id' => SecureRandom.uuid)])

      expect(result.scan('</a>').size).to eq(3)
      expect(result.scan(/href="[^"]+"/).uniq.size).to eq(1)
    end
  end

  describe 'where a number ends' do
    it 'does not match a number that runs on into letters' do
      %w[#42abc #42f].each do |token|
        expect(apply("<p>Siehe #{token} dazu.</p>", [ticket_cite(number: 42)])).not_to include('</a>')
      end
    end

    it 'still matches the first number of a range, which is a real way to write it' do
      expect(apply('<p>Siehe #42-#45 dazu.</p>', [ticket_cite(number: 42)])).to include('</a>')
    end
  end

  # R2 (2026-08-31): the [n] source markers the model writes resolve against the
  # SAME numbering the prompt was built with (SourceNumbering, number n =
  # citations[n-1]) — the link is correct by construction because it can only
  # reach a citation persisted on this very answer.
  describe 'the [n] source markers' do
    def apply_numbered(html, visible:, full:)
      described_class.apply(html: html, citations: visible, organisation: organisation,
                            project: project,
                            numbering: Lalabase::ProjectRag::SourceNumbering.for(full))
    end

    let(:note)   { note_cite(title: 'Kickoff-Protokoll') }
    let(:ticket) { ticket_cite(number: 42) }

    it 'links [n] to the citation the prompt numbered n' do
      result = apply_numbered('<p>Das sagt [2].</p>', visible: [note, ticket], full: [note, ticket])

      expected = Rails.application.routes.url_helpers
                      .organisation_project_ticket_path(organisation, project, ticket['id'])
      expect(result).to include(%(<a href="#{expected}"))
      expect(result).to include('>[2]</a>')
    end

    it 'links EVERY occurrence of the marker' do
      result = apply_numbered('<p>Laut [1] gilt A. Und [1] sagt auch B.</p>',
                              visible: [note], full: [note])

      expect(result.scan('</a>').size).to eq(2)
    end

    it 'leaves an out-of-range number as text' do
      expect(apply_numbered('<p>Das sagt [3].</p>', visible: [note, ticket], full: [note, ticket]))
        .not_to include('</a>')
    end

    it 'leaves a marker as text when its citation is not visible to this viewer' do
      # The numbering spans the FULL list; the viewer's gate hid the ticket. The
      # bare number leaks nothing — its chip is hidden for the same reason.
      result = apply_numbered('<p>Siehe [2], nicht [1].</p>', visible: [note], full: [note, ticket])

      expect(result).not_to include(%(>[2]</a>))
      expect(result).to include(%(>[1]</a>))
    end

    it 'does not confuse [1] with [12] or an index expression' do
      result = apply_numbered('<p>Siehe [12] und items[1] dazu.</p>', visible: [note], full: [note])

      expect(result).not_to include('</a>')
    end

    it 'stays out of code, like every other anchor' do
      result = apply_numbered('<p>Der Wert <code>[1]</code> ist Code.</p>', visible: [note], full: [note])

      expect(result).not_to include('</a>')
    end

    it 'links a time_report marker: the number is unambiguous where the title is not' do
      report = { 'type' => 'time_report', 'area' => 'time_sessions', 'id' => "#{project.id}:abc",
                 'project_id' => project.id, 'title' => project.name, 'filters' => {} }
      result = apply_numbered('<p>Die Auswertung [1] ergibt 12 Stunden.</p>',
                              visible: [report], full: [report])

      expect(result).to include('>[1]</a>')
    end

    it 'leaves a marker for the code layer as text: there is no page to link' do
      cap = { 'type' => 'capability', 'id' => SecureRandom.uuid, 'name' => 'Notifications' }
      expect(apply_numbered('<p>Die Capability [1] kann das.</p>', visible: [cap], full: [cap]))
        .not_to include('</a>')
    end

    it 'changes nothing when no numbering is handed in (old callers)' do
      expect(apply('<p>Das sagt [1].</p>', [note])).not_to include('>[1]</a>')
    end
  end

  # Positive iteration, house style: a new citation type must not slip in without a
  # decision about whether its title is looked for in the prose.
  # The ranking in #next_match: at the same start the LONGER match wins.
  # Without it the shorter title would get the spot, and the link would lead to the
  # wrong object -- visible only because the label ends in the middle of a word.
  describe 'when two titles start at the same place' do
    it 'gives the position to the longer one' do
      short = note_cite(title: 'Kickoff')
      long = note_cite(title: 'Kickoff-Protokoll')

      result = apply('<p>Das Kickoff-Protokoll nennt drei Punkte.</p>', [short, long])

      expect(result).to include(%(>Kickoff-Protokoll</a>))
      expect(result).to include(%(/notes/#{long['id']}"))
      expect(result).not_to include(%(/notes/#{short['id']}"))
    end
  end

  # Help titles are everyday words in an answer ("Zeiterfassung"). The source row links the
  # page; the prose does not (product knowledge S2).
  describe 'a help page' do
    it 'links no mention of its title' do
      help = { 'type' => 'help_page', 'source' => 'help', 'id' => 'guides/features/time-tracking',
               'title' => 'Zeiterfassung' }

      expect(apply('<p>Die Zeiterfassung zeigt es.</p>', [help])).not_to include('<a')
    end
  end

  describe 'the type table' do
    it 'looks for titles and names only among types the citation shapes actually know' do
      expect(described_class::TITLE_TYPES - Lalabase::Citations::TYPES).to be_empty
      expect(described_class::NAME_TYPES - Lalabase::Citations::TYPES).to be_empty
    end

    it 'holds its tables frozen, so nothing can widen them at runtime' do
      expect(described_class::TITLE_TYPES).to be_frozen
      expect(described_class::NAME_TYPES).to be_frozen
      expect(described_class::SKIP_ANCESTORS).to be_frozen
    end

    # ⚠️ The iteration above only checks what IS IN the list: if someone removes 'pre'
    # from the list, it runs over two zones and stays green. Measured, not assumed
    # -- the probe was green at first. That is why the content itself is here, with a
    # reason per entry: a number in a code example is code, and a link inside a link is
    # invalid markup.
    it 'skips the three zones a number must never be linked in' do
      expect(described_class::SKIP_ANCESTORS).to include('a', 'code', 'pre')
    end

    it 'has a decision for EVERY content type: by number, by title, by name, or deliberately not at all' do
      by_number = %w[ticket post]
      # person (People S3): the name, which is what an answer calls a person.
      by_name = described_class::NAME_TYPES
      # time_report: its title is the project name, and it has a panel. help_page: help titles
      # are everyday words in an answer ("Zeiterfassung", "Aktivitäten"); the source row links it.
      deliberately_unlinked = %w[time_report help_page]
      content_types = Lalabase::Citations::CONTENT_TYPES + Lalabase::Citations::PRODUCT_TYPES

      content_types.each do |type|
        decided = by_number.include?(type) || described_class::TITLE_TYPES.include?(type) ||
                  by_name.include?(type) || deliberately_unlinked.include?(type)
        expect(decided).to be(true), "#{type} is matched by nothing and excluded by nobody"
      end
    end
  end
end
