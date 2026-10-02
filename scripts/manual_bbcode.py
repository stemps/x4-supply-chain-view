"""Render the manual at a tag, branch or commit as Nexus BBCode and open the handoff."""
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit

from release_archive import ReleaseError, git_bytes

MANUAL = 'docs/MANUAL.md'


def convert(source):
    try:
        from markdown_it import MarkdownIt
        from markdown_it.tree import SyntaxTreeNode
    except ImportError as error:
        raise ReleaseError('Manual conversion requires markdown-it-py. Run through just release, '
                           'just publish-nexus, or uv run --with markdown-it-py==4.0.0.') from error

    # Recognise these extensions so they fail explicitly instead of leaking Markdown.
    parser = MarkdownIt('commonmark').enable(['table', 'strikethrough'])

    def render(node):
        kind = node.type
        if kind == 'text':
            return node.content
        if kind == 'softbreak':
            return ' '
        if kind == 'hardbreak':
            return '\n'
        supported = {'root', 'inline', 'paragraph', 'heading', 'strong', 'em',
                     'link', 'bullet_list', 'ordered_list', 'list_item'}
        if kind not in supported:
            raise ReleaseError(f'{MANUAL}: unsupported Markdown construct {kind!r}. '
                               'Use headings, paragraphs, emphasis, links or lists instead.')
        if kind == 'ordered_list' and node.attrs.get('start', 1) != 1:
            # Nexus has no ordered-list start attribute. Preserve explicit
            # numbering for continued lists.
            return '\n\n'.join(
                f'{number}. ' + ''.join(render(child) for child in item.children).strip()
                for number, item in enumerate(node.children, node.attrs['start'])
            ) + '\n\n'
        content = ''.join(render(child) for child in node.children)
        if kind in ('root', 'inline'):
            return content
        if kind == 'paragraph':
            return content + '\n\n'
        if kind == 'heading':
            size = {'h1': 5, 'h2': 4, 'h3': 3, 'h4': 2, 'h5': 2, 'h6': 2}[node.tag]
            return f'[b][size={size}]{content}[/size][/b]\n\n'
        if kind in ('strong', 'em'):
            tag = 'b' if kind == 'strong' else 'i'
            return f'[{tag}]{content}[/{tag}]'
        if kind == 'link':
            href = node.attrs['href']
            if urlsplit(href).scheme not in ('https', 'http', 'mailto'):
                raise ReleaseError(f'{MANUAL}: use an absolute https/http/mailto link: {href!r}')
            href = href.replace('[', '%5B').replace(']', '%5D')
            return f'[url={href}]{content}[/url]'
        if kind == 'list_item':
            if re.match(r'^\[[ xX]\] ', content):
                raise ReleaseError(f'{MANUAL}: task lists are unsupported; use ordinary list items.')
            return f'[*]{content.strip()}[/*]\n'
        tag = 'list=1' if kind == 'ordered_list' else 'list'
        return f'[{tag}]\n{content}[/list]\n\n'

    result = render(SyntaxTreeNode(parser.parse(source))).strip()
    if not result:
        raise ReleaseError(f'{MANUAL}: manual must not be empty.')
    return result + '\n'


def from_commit(root, commit):
    return convert(git_bytes(root, 'show', f'{commit}:{MANUAL}').decode('utf-8'))


def resolve(root, ref):
    """Return (commit, output label) for a tag, branch or other commit-ish."""
    if not ref or ref.startswith('-'):
        raise ReleaseError(f'Invalid Git reference: {ref!r}')
    commit = git_bytes(root, 'rev-parse', '--verify', '--quiet',
                       f'{ref}^{{commit}}').decode().strip()
    if re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', ref):
        # Released manuals keep the tag folder that holds the Nexus receipts.
        return commit, ref
    # Branches move, so pin the folder name to the commit actually rendered.
    name = re.sub(r'[^A-Za-z0-9._-]+', '_', ref).strip('._') or 'ref'
    return commit, f'{name}-{commit[:10]}'


def handoff(root, label, commit):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', label):
        raise ReleaseError(f'Unsafe manual output folder name: {label!r}')
    output = from_commit(root, commit)
    path = Path(root).resolve() / 'dist' / 'nexus' / label / 'description.bbcode.txt'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(output, encoding='utf-8', newline='\n')
    print(f'Nexus description ready to paste: {path}')
    # Explicitly requested interactive window. Keep the file after the editor exits.
    subprocess.Popen(['notepad.exe', str(path)])
    return path


if __name__ == '__main__':
    import argparse
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('ref', help='Release tag (vMAJOR.MINOR.PATCH), branch or other commit-ish')
    args = cli.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        commit, label = resolve(root, args.ref)
        handoff(root, label, commit)
    except (ReleaseError, OSError, ValueError) as error:
        print(f'Description handoff failed: {error}', file=sys.stderr)
        sys.exit(1)
