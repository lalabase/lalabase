# frozen_string_literal: true

require 'rails_helper'

# What: Documentation::MarkdownRenderer — markdown → sanitized HTML plus link and
#       image rewriting, including the path-traversal guard.
# Type: Service spec.
# Why:  The markdown comes from an EXTERNAL repo, so rendering must be safe:
#       disallowed HTML stripped, and relative links/images that escape the set
#       (../) must NOT be turned into in-app links or repo URLs.
RSpec.describe Documentation::MarkdownRenderer do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:repository) do
    create(:project_repository, project: project, organisation: organisation,
                                full_name: 'acme/handbook', default_branch: 'main')
  end
  let(:set) do
    create(:documentation_set, project: project, project_repository: repository, path_prefix: '.lalabase/doku/')
  end

  before { ActsAsTenant.current_tenant = organisation }

  def render(markdown, page_path: 'guide/intro.md')
    described_class.new(documentation_set: set, page_path: page_path).render(markdown)
  end

  def render_result(markdown, page_path: 'guide/intro.md')
    described_class.new(documentation_set: set, page_path: page_path).render_with_references(markdown)
  end

  it 'returns an empty string for blank input' do
    expect(render(nil)).to eq('')
    expect(render('')).to eq('')
  end

  it 'renders basic markdown to HTML' do
    html = render("# Title\n\nHello **world**.")
    expect(html).to include('<h1>Title</h1>')
    expect(html).to include('<strong>world</strong>')
  end

  it 'strips disallowed HTML (defense in depth against untrusted repo content)' do
    html = render("Safe <script>alert('x')</script> text")
    expect(html).not_to include('<script>')
    expect(html).to include('Safe')
  end

  it 'neutralises a javascript: link so it is not clickable' do
    html = render('[click me](javascript:alert(1))')
    expect(html).not_to include('javascript:alert')
  end

  it 'renders GFM tables (table tags are on the allowlist)' do
    html = render("| A | B |\n|---|---|\n| 1 | 2 |")
    expect(html).to include('<table>')
    expect(html).to include('<td>1</td>')
  end

  describe 'internal .md links' do
    it 'rewrites a relative .md link to the in-app documentation route' do
      html = render('See [setup](setup.md).')
      expect(html).to include('/documentation')
      expect(html).to include('page=guide%2Fsetup.md').or include('page=guide/setup.md')
    end

    it 'preserves a #anchor on a rewritten link' do
      html = render('[top](setup.md#intro)')
      expect(html).to include('#intro')
    end

    it 'matches the .md extension case-insensitively' do
      html = render('[x](setup.MD)')
      expect(html).to include('/documentation')
      expect(html).to include('page=guide%2Fsetup.MD').or include('page=guide/setup.MD')
    end

    it 'leaves absolute links untouched' do
      html = render('[docs](https://example.com/page.md)')
      expect(html).to include('href="https://example.com/page.md"')
      expect(html).not_to include('/documentation?')
    end

    it 'leaves non-.md and anchor links untouched' do
      html = render('[home](../index.html) and [jump](#section)')
      expect(html).to include('#section')
      expect(html).not_to include('page=')
    end
  end

  describe 'relative images' do
    it 'rewrites a relative image source to the raw repo URL' do
      html = render('![logo](img/logo.png)')
      expect(html).to include('src="https://raw.githubusercontent.com/acme/handbook/main/.lalabase/doku/guide/img/logo.png"')
    end

    it 'leaves absolute image sources untouched' do
      html = render('![x](https://cdn.example.com/x.png)')
      expect(html).to include('src="https://cdn.example.com/x.png"')
    end

    it 'never embeds the repository access token in the raw URL' do
      html = render('![logo](img/logo.png)')
      expect(html).to include('raw.githubusercontent.com') # sanity: it did rewrite
      expect(html).not_to include(repository.access_token)
    end
  end

  describe 'knowledge links (lalabase://)' do
    def create_document(title: 'Design Doc')
      doc = create(:document, project: project, organisation: organisation)
      version = create(:document_version, document: doc, organisation: organisation, title: title)
      doc.update!(current_version: version)
      doc
    end

    it 'rewrites a note link to the in-app note path and collects the target' do
      note = create(:note, project: project, organisation: organisation, title: 'Secret Runbook')
      result = render_result("See [the runbook](lalabase://note/#{note.id}).")

      expect(result.html).to include(%(href="/org/#{organisation.id}/projects/#{project.id}/notes/#{note.id}"))
      expect(result.references).to eq([note])
    end

    it 'rewrites a document link too (both target types resolve)' do
      document = create_document
      result = render_result("See [the doc](lalabase://document/#{document.id}).")

      expect(result.html).to include(%(href="/org/#{organisation.id}/projects/#{project.id}/documents/#{document.id}"))
      expect(result.references).to eq([document])
    end

    it 'keeps the author-written display text (never leaks the target title)' do
      # The note's title must NOT appear — a doc reader without notes access would
      # otherwise learn it through the link text. Only the author's words stay.
      note = create(:note, project: project, organisation: organisation, title: 'Confidential Title')
      result = render_result("Read [my label](lalabase://note/#{note.id}).")

      expect(result.html).to include('my label')
      expect(result.html).not_to include('Confidential Title')
    end

    it 'dedups two links to the same note into one reference (unique-index-friendly)' do
      note = create(:note, project: project, organisation: organisation)
      result = render_result("[a](lalabase://note/#{note.id}) and [b](lalabase://note/#{note.id})")

      expect(result.references).to eq([note])
    end

    it 'collects TWO distinct targets and still rewrites a .md link + image in the same pass' do
      note = create(:note, project: project, organisation: organisation, title: 'N')
      document = create_document(title: 'D')
      markdown = <<~MD
        [n](lalabase://note/#{note.id}) and [d](lalabase://document/#{document.id})
        see [guide](setup.md) and ![pic](img/logo.png)
        and a dead one [x](lalabase://note/#{SecureRandom.uuid})
      MD

      result = render_result(markdown)

      # Both distinct knowledge targets collected; the dead link contributes none.
      expect(result.references).to contain_exactly(note, document)
      expect(result.html).to include("/notes/#{note.id}")
      expect(result.html).to include("/documents/#{document.id}")
      # The other rewrite branches still fire (knowledge branch does not shadow them).
      expect(result.html).to include('/documentation')            # internal .md link
      expect(result.html).to include('raw.githubusercontent.com') # relative image
    end

    it 'does NOT resolve a note from another project (no cross-project link), no reference' do
      other_project = create(:project, organisation: organisation)
      foreign = create(:note, project: other_project, organisation: organisation)
      result = render_result("[x](lalabase://note/#{foreign.id})")

      expect(result.references).to eq([])
      expect(result.html).not_to include("/notes/#{foreign.id}")
    end

    it 'does NOT resolve a cross-tenant note (T6 rest), no reference' do
      other_org = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other_org) do
        create(:note, project: create(:project, organisation: other_org), organisation: other_org)
      end
      result = render_result("[x](lalabase://note/#{foreign.id})")

      expect(result.references).to eq([])
    end

    it 'renders "unknown UUID" and "foreign project" identically (no existence oracle)' do
      other_project = create(:project, organisation: organisation)
      foreign = create(:note, project: other_project, organisation: organisation)

      unknown_html = render_result("[x](lalabase://note/#{SecureRandom.uuid})").html
      foreign_html = render_result("[x](lalabase://note/#{foreign.id})").html

      # Same anchor text, both dropped to a plain non-link by the sanitizer.
      expect(unknown_html).to eq(foreign_html)
      expect(unknown_html).not_to include('lalabase://')
    end

    it 'drops the unknown lalabase: scheme from an unresolved link (not clickable)' do
      result = render_result("[x](lalabase://note/#{SecureRandom.uuid})")
      expect(result.html).to include('x') # the text survives
      expect(result.html).not_to include('href="lalabase') # but the scheme is stripped
    end

    it 'leaves an unknown type untouched and adds no reference' do
      result = render_result("[x](lalabase://ticket/#{SecureRandom.uuid})")
      expect(result.references).to eq([])
    end

    it 'the string render entry point also rewrites knowledge links' do
      note = create(:note, project: project, organisation: organisation)
      html = render("[go](lalabase://note/#{note.id})")
      expect(html).to include("/notes/#{note.id}")
    end
  end

  describe 'path-traversal guard' do
    it 'still rewrites a ../ link that stays inside the set (guard is not over-eager)' do
      # From guide/advanced/x.md, ../setup.md resolves to guide/setup.md — inside
      # the set, so it MUST be rewritten. Only escapes are dropped.
      html = described_class.new(documentation_set: set, page_path: 'guide/advanced/x.md').render('[s](../setup.md)')
      expect(html).to include('/documentation')
      expect(html).to include('page=guide%2Fsetup.md').or include('page=guide/setup.md')
    end

    it 'does not turn a link escaping the set into an in-app link' do
      html = render('[leak](../../../secret.md)')
      # Left as the original relative href, NOT rewritten to a documentation route.
      expect(html).not_to include('page=')
      expect(html).not_to include('/documentation')
    end

    it 'does not turn an image escaping the set into a repo URL' do
      html = render('![leak](../../../secret.png)')
      expect(html).not_to include('raw.githubusercontent.com')
    end
  end
end
