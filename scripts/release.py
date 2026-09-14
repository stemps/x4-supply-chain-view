"""Interactive, Git-backed release builder with a Markdown-to-BBCode handoff."""
from __future__ import annotations

import datetime
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

from release_archive import ReleaseError, working_files, write_zip, git_bytes


def version_tuple(value):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value):
        raise ReleaseError("Use a stable major.minor.patch version, without a v prefix.")
    parts = tuple(map(int, value.split(".")))
    if parts[1] >= 100 or parts[2] >= 100:
        raise ReleaseError("Minor and patch must be below 100 for X4's version encoding.")
    return parts


class Release:
    metadata = ("VERSION", "CHANGELOG.md", "content.xml")

    def __init__(self, root):
        self.root = Path(root).resolve()

    def git(self, *args):
        result = subprocess.run(["git", *args], cwd=self.root, capture_output=True)
        if result.returncode:
            raise ReleaseError(result.stderr.decode("utf-8", errors="replace").strip()
                               or f"git {' '.join(args)} failed")
        return result.stdout.decode("utf-8").rstrip("\r\n")

    def status(self):
        return self.git("status", "--porcelain=v1", "--untracked-files=all")

    def preflight(self):
        if self.git("rev-parse", "--show-toplevel").replace("\\", "/").lower() != self.root.as_posix().lower():
            raise ReleaseError("Run against the mod repository root.")
        if self.git("branch", "--show-current") != "main":
            raise ReleaseError("Release requires branch main.")
        if self.status():
            raise ReleaseError("Commit and push all local changes, including untracked files, first.")
        for marker in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"):
            if (self.root / self.git("rev-parse", "--git-path", marker)).exists():
                raise ReleaseError("Finish the in-progress Git operation before releasing.")
        if self.git("rev-parse", "--is-shallow-repository") == "true":
            raise ReleaseError("Fetch complete history before generating release notes.")
        if self.git("rev-parse", "--abbrev-ref", "@{upstream}") != "origin/main":
            raise ReleaseError("main must track origin/main.")
        self.git("fetch", "--tags", "origin", "+refs/heads/main:refs/remotes/origin/main")
        head = self.git("rev-parse", "HEAD")
        if head != self.git("rev-parse", "origin/main"):
            raise ReleaseError("Local main differs from origin/main. Commit, push or synchronize first.")
        if self.status():
            raise ReleaseError("Working tree changed during preflight.")
        return head

    def previous(self):
        tags = self.git("tag", "--list", "v*").splitlines()
        releases = []
        for tag in tags:
            if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
                releases.append((version_tuple(tag[1:]), tag))
        path = self.root / "VERSION"
        if not releases:
            if path.exists():
                raise ReleaseError("VERSION exists without a release tag; resolve release history first.")
            return None, "0.1.0"
        parts, tag = max(releases)
        self.git("merge-base", "--is-ancestor", tag, "HEAD")
        if not path.exists() or path.read_text(encoding="utf-8").strip() != tag[1:]:
            raise ReleaseError("VERSION must agree with the latest release tag.")
        major, minor, _ = parts
        suggested = f"{major}.{minor + 1}.0" if minor < 99 else f"{major + 1}.0.0"
        return tag, suggested

    def notes(self, previous):
        history = f"{previous}..HEAD" if previous else "HEAD"
        subjects = self.git("log", "--reverse", "--format=%s", history).splitlines()
        editor = self.git("var", "GIT_EDITOR")
        with tempfile.TemporaryDirectory(prefix="scv-notes-") as directory:
            path = Path(directory) / "release-notes.md"
            path.write_text("\n".join(f"- {s}" for s in subjects) + "\n", encoding="utf-8")
            # Git editors are shell command strings. Let Git's shell interpret the
            # configured editor, but pass the filename as a separate positional arg.
            result = subprocess.run(
                ["git", "-c", 'alias.scv-release-editor=!' + editor + ' "$SCV_NOTES"',
                 "scv-release-editor"], cwd=self.root,
                env={**os.environ, "GIT_EDITOR": editor, "SCV_NOTES": str(path)})
            if result.returncode:
                raise ReleaseError("Release notes editor failed.")
            notes = path.read_text(encoding="utf-8").strip()
        if not notes or not re.search(r"[\w]", notes):
            raise ReleaseError("Release notes must not be empty.")
        return notes

    def updated_metadata(self, version, notes):
        major, minor, patch = version_tuple(version)
        date = datetime.date.today().isoformat()
        manifest = (self.root / "content.xml").read_bytes()
        match = re.search(rb"<content\b[^>]*>", manifest)
        if not match:
            raise ReleaseError("Missing content manifest root.")
        opening = match.group()
        for attribute, value in ((b"version", str(major * 10000 + minor * 100 + patch)), (b"date", date)):
            pattern = rb"(\s" + attribute + rb"\s*=\s*)([\"'])(.*?)\2"
            opening, count = re.subn(pattern, lambda m: m[1] + m[2] + value.encode() + m[2], opening)
            if count != 1:
                raise ReleaseError(f"Expected one {attribute.decode()} attribute on content root.")
        manifest = manifest[:match.start()] + opening + manifest[match.end():]
        changelog = self.root / "CHANGELOG.md"
        old = changelog.read_text(encoding="utf-8") if changelog.exists() else "# Changelog\n"
        if not old.startswith("# Changelog\n"):
            raise ReleaseError("CHANGELOG.md must start with '# Changelog'.")
        new = f"# Changelog\n\n## {version} - {date}\n\n{notes}\n\n" + old[len("# Changelog\n"):].lstrip()
        return {"VERSION": (version + "\n").encode(), "CHANGELOG.md": new.encode(), "content.xml": manifest}

    def runtime_files(self):
        return working_files(self.root)

    def build_zip(self, path, files):
        write_zip(path, files, lambda name: (self.root / name).read_bytes())

    def check_unchanged(self, head, written):
        if self.git("branch", "--show-current") != "main" or self.git("rev-parse", "HEAD") != head:
            raise ReleaseError("Branch or HEAD changed during release.")
        if self.git("diff", "--cached", "--name-only"):
            raise ReleaseError("Index changed during release.")
        # -z avoids quoted/escaped paths and keeps names with spaces intact.
        changed = self.git("status", "--porcelain=v1", "-z", "--untracked-files=all")
        paths = [entry[3:] for entry in changed.split("\0") if entry]
        if set(paths) - set(written):
            raise ReleaseError("Unrelated files changed during release.")
        for name, data in written.items():
            if (self.root / name).read_bytes() != data:
                raise ReleaseError(f"Concurrent modification to {name}.")

    def run(self, ask=input, check=None, publisher=None):
        head = self.preflight()
        from manual_bbcode import from_commit
        from_commit(self.root, head)
        previous, suggested = self.previous()
        version = ask(f"Next version [{suggested}]: ").strip() or suggested
        parts = version_tuple(version)
        if previous and parts <= version_tuple(previous[1:]):
            raise ReleaseError("Version must increase.")
        tag = "v" + version
        if tag in self.git("tag", "--list").splitlines():
            raise ReleaseError(f"Tag {tag} already exists.")
        final = self.root / "dist" / f"Supply-Chain-View-{version}.zip"
        if final.exists():
            raise ReleaseError(f"Archive already exists: {final}")
        notes = self.notes(previous)
        if publisher:
            publisher.preflight(version, notes)
        written = self.updated_metadata(version, notes)
        self.check_unchanged(head, {})
        originals = {p: (self.root / p).read_bytes() if (self.root / p).exists() else None for p in written}
        committed = False
        staged = False
        try:
            for name, data in written.items():
                (self.root / name).write_bytes(data)
            if check:
                check()
            else:
                subprocess.run(["just", "check"], cwd=self.root, check=True)
            self.check_unchanged(head, written)
            files = self.runtime_files()
            with tempfile.TemporaryDirectory(prefix="scv-release-") as directory:
                archive = Path(directory) / final.name
                self.build_zip(archive, files)
                self.check_unchanged(head, written)
                self.git("add", "--", *self.metadata)
                staged = True
                self.git("commit", "-m", f"Release {tag}", "--", *self.metadata)
                committed = True
                commit = self.git("rev-parse", "HEAD")
                if self.git("rev-parse", "HEAD^") != head:
                    raise ReleaseError("Unexpected release commit parent.")
                changed = self.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").splitlines()
                if set(changed) - set(self.metadata):
                    raise ReleaseError("Release commit contains unrelated changes.")
                # Hooks must not silently change the release contents.
                if self.status():
                    raise ReleaseError("Working tree changed during release commit.")
                with zipfile.ZipFile(archive) as built:
                    for name in files:
                        digest = subprocess.run(["git", "hash-object", "--stdin", "--path", name],
                                                input=built.read("supply_chain_view/" + name), cwd=self.root,
                                                capture_output=True, check=True).stdout.decode().strip()
                        if digest != self.git("rev-parse", f"HEAD:{name}"):
                            raise ReleaseError(f"Committed file differs from archive: {name}")
                # Public archives use canonical committed bytes so a missing ZIP
                # can be reconstructed identically, including on Windows.
                canonical = Path(directory) / ('canonical-' + final.name)
                write_zip(canonical, files, lambda name: git_bytes(self.root, 'show', f'{commit}:{name}'))
                archive = canonical
                note_file = Path(directory) / "tag-notes.md"
                note_file.write_text(notes + "\n", encoding="utf-8")
                self.git("tag", "-a", tag, "-F", str(note_file), commit)
                self.git("push", "--atomic", "origin", f"{commit}:refs/heads/main", f"refs/tags/{tag}:refs/tags/{tag}")
                final.parent.mkdir(exist_ok=True)
                # Exclusive creation prevents races from overwriting an existing ZIP.
                with final.open("xb") as destination:
                    destination.write(archive.read_bytes())
            print(f"Released {tag}: {final}")
            return final
        except BaseException:
            if committed or self.git("rev-parse", "HEAD") != head:
                print(f"Release commit retained. Inspect git status and tag {tag}. "
                      f"If the tag exists, retry: git push --atomic origin main {tag}. "
                      "No rollback was performed. Rebuild any missing ZIP from the verified tag.", file=sys.stderr)
            else:
                if staged:
                    self.git("reset", "--quiet", head, "--", *self.metadata)
                for name, data in written.items():
                    path = self.root / name
                    if path.exists() and path.read_bytes() == data:
                        if originals[name] is None:
                            path.unlink()
                        else:
                            path.write_bytes(originals[name])
            raise


def main():
    import argparse
    from release_archive import local_zip, tagged_zip
    from nexus_publish import Publisher
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['release', 'build-zip', 'publish-nexus'], nargs='?', default='release')
    parser.add_argument('tag', nargs='?')
    parser.add_argument('--adopt-version', help='Verified Nexus version ID after an uncertain creation')
    parser.add_argument('--retry-version', action='store_true', help='Confirm uncertain creation failed, then retry')
    parser.add_argument('--changelog-status', choices=['posted', 'not-posted'], help='Resolve an uncertain changelog submission')
    args = parser.parse_args()
    if args.command != 'publish-nexus' and (args.adopt_version or args.retry_version or args.changelog_status):
        parser.error('Recovery flags are only valid with publish-nexus')
    if args.adopt_version and args.retry_version:
        parser.error('--adopt-version and --retry-version are mutually exclusive')
    root = Path(__file__).resolve().parents[1]
    if args.command == 'build-zip':
        if args.tag:
            parser.error('build-zip takes no tag')
        local_zip(root)
        return
    publisher = Publisher(root)
    if args.command == 'release':
        if args.tag:
            parser.error('release takes no tag')
        archive = Release(root).run(publisher=publisher)
        tag = 'v' + archive.stem.removeprefix('Supply-Chain-View-')
    else:
        if not args.tag:
            parser.error('publish-nexus requires a tag')
        tag = args.tag
    try:
        archive, commit, notes = tagged_zip(root, tag)
        from manual_bbcode import from_commit, handoff
        from_commit(root, commit)
        publisher.publish(tag, commit, archive, notes, adopt_version=args.adopt_version,
                          retry_version=args.retry_version, changelog_status=args.changelog_status)
    except (ReleaseError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        raise ReleaseError(f'Nexus publication incomplete: {error}\n'
                           f'Git release retained. Resume: just publish-nexus {tag}') from None
    try:
        handoff(root, tag, commit)
    except (ReleaseError, OSError, ValueError) as error:
        print(f'Nexus publication succeeded, but the description handoff failed: {error}\n'
              'No publication retry is needed. Open the generated file if present, or run:\n'
              f'just nexus-description {tag}', file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, subprocess.CalledProcessError, OSError, ValueError, KeyboardInterrupt, EOFError) as error:
        print(f"Release aborted: {error}", file=sys.stderr)
        sys.exit(1)
